#if os(macOS) || os(Linux)
import Foundation
import JSONFoundation
import JSONRPCPeer

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An agent's stdio, spoken as acpx's client speaks it, on a process started here
/// (``ChildProcess``) so that how the agent ends is known — acpx's
/// `attachAgentLifecycleObservers`:
///
/// - its stdout is read by acpx's rules (``AgentOutputReader``); a line too long fails
///   the connection with ``AcpMessageLimitError``;
/// - the first sign of its end is what it is put down to (``AgentExit``): the process
///   exiting (`process_exit`), its stdout closing while it still runs (`pipe_close`),
///   or the connection ending another way (`connection_close`). Requests still waiting
///   then fail with ``AgentDisconnectedError``, which names it;
/// - its stderr is kept, the last 8,192 characters of it, for ``AgentStartupError``,
///   passed on to this process's stderr when `inheritStderr` says so — acpx shows it
///   only with `--verbose` — and shown to the tap (``RawWireTap/onStderr(_:)``);
/// - ``terminate()`` ends it as acpx's `cleanupAgentProcess` does.
final class AgentProcessTransport: JSONRPCMessageTransport, @unchecked Sendable {
    let process: ChildProcess
    /// When it was started, in acpx's ISO 8601 form.
    let startedAt: String
    private let tap: RawWireTap
    private let inheritStderr: Bool
    private let quirks: AgentCommandQuirks
    private let inbound: AsyncThrowingStream<JSONRPCMessage, any Error>
    private let inboundContinuation: AsyncThrowingStream<JSONRPCMessage, any Error>.Continuation
    /// What the reader thread read, handed to a task that shows it to the tap and
    /// passes it on — in the context the transport was started in, whose task-local
    /// values the tap's observer may need — and, last, the end.
    private let events: AsyncStream<ReadEvent>.Continuation
    private let eventStream: AsyncStream<ReadEvent>
    private let writer: MessageWriter
    /// The processes the agent started, as last seen. Looked at under ``descendantsLock``.
    private let descendants: ProcessDescendants
    private let descendantsLock = NSLock()
    /// For tests: signalled once the transport has looked at whether the agent is exiting,
    /// which the exit's reaping then waits for (`reapsLate`).
    private let exitLookedAt: DispatchSemaphore?

    private let lock = NSLock()
    /// Touched only by the reader thread.
    private var reader: AgentOutputReader
    private var stderr = StderrTail()
    private var exitStatus: TerminalExitStatus?
    private var lastExit: AgentExit?
    private var exitWaits: [UUID: ExitWait] = [:]
    /// The ids of the `session/prompt` requests not answered yet.
    private var promptsInFlight: Set<JSONRPCID> = []
    private var closing = false
    /// Set by a close until its agent has had its stdin's grace (``settleHeldEnd(quitOnStdinEnd:)``).
    private var holdingEnd = false
    private var termination: Task<Void, Never>?

    private init(
        process: ChildProcess, agentCommand: String, maxMessageBytes: Int?, inheritStderr: Bool, tap: RawWireTap,
        reapsLate: Bool
    ) {
        self.process = process
        startedAt = AgentProcessTransport.now()
        self.tap = tap
        self.inheritStderr = inheritStderr
        quirks = AgentCommandQuirks(agentCommand)
        reader = AgentOutputReader(agentCommand: agentCommand, maxMessageBytes: maxMessageBytes)
        (inbound, inboundContinuation) = AsyncThrowingStream.makeStream()
        (eventStream, events) = AsyncStream.makeStream()
        writer = MessageWriter(process: process, tap: tap)
        descendants = ProcessDescendants(root: process.pid, ownProcessGroup: false)
        exitLookedAt = reapsLate ? DispatchSemaphore(value: 0) : nil
    }

    /// Start the agent `launch` describes and begin reading it.
    ///
    /// - Parameters:
    ///   - agentCommand: the command the agent was started with, for its quirks.
    ///   - maxMessageBytes: the longest line read from it, `nil` for no limit.
    ///   - reapsLate: for tests, the latest its exit can be reaped, as under load: only
    ///     once the transport, its stdout ended, has looked at whether it is exiting.
    /// - Throws: ``ChildProcess/SpawnError`` when it cannot be started.
    static func start(
        _ launch: ProcessLaunch, agentCommand: String, maxMessageBytes: Int?, tap: RawWireTap,
        reapsLate: Bool = false
    ) throws -> AgentProcessTransport {
        let process = try ChildProcess.spawn(
            command: launch.executable, arguments: launch.arguments,
            cwd: launch.workingDirectory ?? FileManager.default.currentDirectoryPath,
            environment: launch.environment, input: true, newSession: false)
        let transport = AgentProcessTransport(
            process: process, agentCommand: agentCommand, maxMessageBytes: maxMessageBytes,
            inheritStderr: launch.inheritStderr, tap: tap, reapsLate: reapsLate)
        transport.begin()
        return transport
    }

    /// What the reader thread passes on.
    private enum ReadEvent {
        case message(JSONRPCMessage, Data)
        case object(Data)
        case end(any Error)
    }

    private func begin() {
        // Weakly: the transport owns the writer.
        writer.onFailure = { [weak self] in self?.writeFailed() }
        _ = Task { [self, eventStream] in
            for await event in eventStream {
                switch event {
                case .message(let message, let body):
                    tap.observe(.inbound, body)
                    inboundContinuation.yield(message)
                case .object(let body):
                    tap.observe(.inbound, body)
                case .end(let error):
                    inboundContinuation.finish(throwing: error)
                }
            }
        }
        writer.start()
        process.start(
            onChunk: { [self] output, bytes in
                switch output {
                case .stdout: read(bytes)
                case .stderr: readStderr(bytes)
                }
            },
            onClose: { [self] output in
                if output == .stdout { stdoutClosed() }
            },
            onExit: { [self] status in exited(status) },
            beforeReaping: exitLookedAt.map { lookedAt in { @Sendable in lookedAt.wait() } })
    }

    // MARK: - JSONRPCMessageTransport

    func send(_ message: JSONRPCMessage) throws {
        let body = try message.encoded()
        if case .request(let request) = message, request.method == "session/prompt" {
            lock.withLock { _ = promptsInFlight.insert(request.id) }
        }
        try writer.enqueue(body)
    }

    func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, any Error> {
        inbound
    }

    /// Stop the transport: nothing more is sent, and the agent is ended in the background
    /// (``terminate()`` waits for it). Its end is as acpx's `close()` sees it, which ends the
    /// agent before it closes the connection (#142): never unexpected, `connection_close` for
    /// an agent that quits once its stdin ends, how its process ended for one signalled.
    func close() {
        lock.withLock { if termination == nil, lastExit == nil { holdingEnd = true } }
        _ = startTermination()
    }

    // MARK: - Lifecycle

    /// acpx's `getAgentLifecycleSnapshot`.
    var lifecycle: AgentLifecycleSnapshot {
        lock.withLock {
            AgentLifecycleSnapshot(
                pid: process.pid, startedAt: startedAt, running: exitStatus == nil, lastExit: lastExit)
        }
    }

    /// What the agent printed on stderr, whitespace collapsed — acpx's
    /// `summarizeStartupStderr`; `nil` if nothing.
    var stderrSummary: String? { lock.withLock { stderr.summary } }

    /// Wait up to `timeout` for the process to exit. Returns whether it has.
    func waitForExit(timeout: Duration) async -> Bool {
        let id = UUID()
        let timer = Task { [self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                guard case .waiting(let continuation)? = exitWaits[id] else {
                    exitWaits[id] = .timedOut
                    return nil
                }
                exitWaits[id] = nil
                return continuation
            }
            waiting?.resume()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let over: Bool = lock.withLock {
                if exitStatus != nil || exitWaits[id] != nil { return true }
                exitWaits[id] = .waiting(continuation)
                return false
            }
            if over { continuation.resume() }
        }
        timer.cancel()
        return lock.withLock {
            exitWaits[id] = nil
            return exitStatus != nil
        }
    }

    /// One ``waitForExit(timeout:)``: waiting, or over before it began to.
    private enum ExitWait {
        case waiting(CheckedContinuation<Void, Never>)
        case timedOut
    }

    private func wakeExitWaiters() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { exitWaits = [:] }
            return exitWaits.values.compactMap {
                if case .waiting(let continuation) = $0 { return continuation }
                return nil
            }
        }
        waiting.forEach { $0.resume() }
    }

    /// Note the processes the agent has started so far — acpx looks once `initialize` is over — so
    /// they are ended with it even if it is gone by then and they have been handed to `init`. A
    /// look that fails is told to the tap when `noting`, as acpx's `captureAgentDescendants` logs it.
    func captureDescendants(noting: Bool = false) {
        let captured = descendantsLock.withLock { descendants.capture(rootIsRunning: !process.hasBeenReaped) }
        if !captured, noting { tap.log("could not verify agent descendants; skipping unverified process cleanup") }
    }

    // MARK: - Reading

    /// acpx's `createNdJsonMessageStream` read side. Called on the reader thread.
    private func read(_ bytes: [UInt8]) {
        let lines: [AgentOutputReader.Line]
        do {
            lines = try reader.push(bytes)
        } catch {
            // acpx's `onReadError`: the connection, then the agent, goes, recorded before what
            // waits fails with the limit's error — a close that leads to is not the end.
            process.stopReading()
            if !recordDisconnect(.connectionClose, failing: error) { events.yield(.end(error)) }
            _ = startTermination()
            return
        }
        for line in lines {
            switch line {
            case .message(let message, let body):
                settlePrompt(answeredBy: message)
                events.yield(.message(message, body))
            case .object(let body):
                events.yield(.object(body))
            case .unparseable(let text, let error):
                // `console.error("Failed to parse JSON message:", trimmedLine, err)`: the
                // error's first line — its stack names acpx's own files.
                let report = "Failed to parse JSON message: \(text) SyntaxError: \(error)\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }

    private func settlePrompt(answeredBy message: JSONRPCMessage) {
        let id: JSONRPCID?
        switch message {
        case .response(let response): id = response.id
        case .errorResponse(let response): id = response.id
        default: id = nil
        }
        guard let id else { return }
        lock.withLock { _ = promptsInFlight.remove(id) }
    }

    /// acpx's `captureStartupStderr`, and `--verbose`'s pass-through.
    private func readStderr(_ bytes: [UInt8]) {
        lock.withLock { stderr.append(bytes) }
        if inheritStderr { FileHandle.standardError.write(Data(bytes)) }
        tap.stderr(Data(bytes))
    }

    /// Stdout reached its end. The process exiting closes it too, and Node reports
    /// that exit before the pipe's close; the end is put down to the pipe only if the
    /// process is still running a moment later.
    private func stdoutClosed() {
        Task {
            if await exits(within: .milliseconds(100)) { return }
            recordDisconnect(.pipeClose)
            // acpx's `handleAgentDisconnect`: an agent whose connection is gone is ended.
            _ = startTermination()
        }
    }

    /// A message could not be written: the agent closed its stdin. Unless the agent is
    /// exiting — as it usually is — that ends the connection, and the agent with it.
    private func writeFailed() {
        Task {
            if await exits(within: .milliseconds(100)) { return }
            recordDisconnect(.connectionClose)
            _ = startTermination()
        }
    }

    /// Whether the process exits within `timeout`, or has begun to by then. Its exit is
    /// recorded once it has been reaped (``exited(_:)``), which under load can come well
    /// after the exit began: one under way is given 5 s more. An exit that stalls past
    /// that — a process can hang in its exit — is left to the caller's account of the end.
    private func exits(within timeout: Duration) async -> Bool {
        if await waitForExit(timeout: timeout) { return true }
        let exiting = process.isExiting
        exitLookedAt?.signal()
        guard exiting else { return false }
        return await waitForExit(timeout: .seconds(5))
    }

    /// The process exited and was reaped, after all it wrote was read. acpx's `exit`
    /// observer: the end is recorded, and the agent's leftovers are retired.
    private func exited(_ status: Int32?) {
        let exit = ChildProcess.exitStatus(status)
        lock.withLock { exitStatus = exit }
        recordDisconnect(.processExit)
        wakeExitWaiters()
        _ = startTermination()
    }

    /// acpx's `recordAgentExit`: the first account of the agent's end wins, and the requests
    /// still waiting fail with it, or with `error`. Once the client is closing, the end is its
    /// own doing. One seen while a close holds it back is left to the close; one without
    /// `status` has no code or signal, as the connection's has. Returns whether it counted.
    @discardableResult
    private func recordDisconnect(_ reason: AgentDisconnectReason, status: Bool = true, failing error: Error? = nil)
        -> Bool {
        let recorded: AgentExit? = lock.withLock {
            guard lastExit == nil, !holdingEnd else { return nil }
            let exit = AgentExit(
                exitCode: status ? exitStatus?.exitCode : nil, signal: status ? exitStatus?.signal : nil,
                exitedAt: Self.now(), reason: reason, unexpectedDuringPrompt: !closing && !promptsInFlight.isEmpty)
            lastExit = exit
            return exit
        }
        guard let recorded else { return false }
        writer.finish()
        events.yield(.end(error ?? AgentDisconnectedError(
            reason: recorded.reason, exitCode: recorded.exitCode, signal: recorded.signal)))
        events.finish()
        return true
    }

    // MARK: - Ending the agent

    /// End the agent as acpx's `cleanupAgentProcess` does, within 8 s: its descendants
    /// noted, its stdin closed, 100 ms (750 for `qodercli`) to exit on its own, then
    /// `SIGTERM` to it and them with 1.5 s to go, then `SIGKILL` with 1 s. Returns once
    /// it is over; a second call waits for the first.
    func terminate() async {
        await startTermination().value
    }

    private func startTermination() -> Task<Void, Never> {
        lock.withLock {
            closing = true
            if let termination { return termination }
            let task = Task { await self.cleanUp() }
            termination = task
            return task
        }
    }

    private func cleanUp() async {
        let deadline = ContinuousClock.now + .seconds(8)
        func remaining(atMost limit: Duration) -> Duration {
            max(.zero, min(limit, deadline - ContinuousClock.now))
        }
        captureDescendants()
        writer.finish()
        settleHeldEnd(quitOnStdinEnd: await exits(within: remaining(atMost: quirks.closeAfterStdinEnd)))
        if await !signalAgentAndDescendants(SIGTERM, waiting: remaining(atMost: .milliseconds(1500))) {
            tap.log("agent processes did not exit after SIGTERM; forcing SIGKILL")
            _ = await signalAgentAndDescendants(SIGKILL, waiting: remaining(atMost: .milliseconds(1000)))
        }
        descendantsLock.withLock { descendants.retire() }
        process.stopReading()
        // acpx closes the connection once the agent is ended: its end, unless one was seen.
        recordDisconnect(.connectionClose)
    }

    /// The end a close held back: an agent that quit in its stdin's grace is `connection_close`,
    /// one of the two ends acpx records for it (its exit and its output's end race); one still
    /// running ends as its process does, as ``exited(_:)`` records it (here, if it just did).
    private func settleHeldEnd(quitOnStdinEnd quit: Bool) {
        let (held, exited) = lock.withLock { () -> (Bool, Bool) in
            defer { holdingEnd = false }
            return (holdingEnd, exitStatus != nil)
        }
        guard held else { return }
        if quit {
            recordDisconnect(.connectionClose, status: false)
        } else if exited {
            recordDisconnect(.processExit)
        }
    }

    /// acpx's `signalAgentAndDescendants`: the descendants first, then the agent, and
    /// wait for all of them. Returns whether they have all exited.
    private func signalAgentAndDescendants(_ signal: Int32, waiting timeout: Duration) async -> Bool {
        descendantsLock.withLock {
            if descendants.capture(rootIsRunning: !process.hasBeenReaped) { descendants.signalTracked(signal) }
        }
        process.send(signal)
        let deadline = ContinuousClock.now + timeout
        let exited = await waitForExit(timeout: timeout)
        // acpx's `ProcessDescendants.waitForExit`: a fresh look every 100 ms.
        while descendantsLock.withLock({
            descendants.capture(rootIsRunning: !process.hasBeenReaped) && descendants.hasTrackedProcesses
        }) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: min(.milliseconds(100), deadline - ContinuousClock.now))
        }
        return exited
    }

    /// acpx's `isoNow()`: `new Date().toISOString()`.
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
#endif
