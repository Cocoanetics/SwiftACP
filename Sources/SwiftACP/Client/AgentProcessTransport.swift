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
///   and passed on to this process's stderr when `inheritStderr` says so — acpx shows
///   it only with `--verbose`;
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
    private var termination: Task<Void, Never>?

    private init(
        process: ChildProcess, agentCommand: String, maxMessageBytes: Int?, inheritStderr: Bool, tap: RawWireTap
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
    }

    /// Start the agent `launch` describes and begin reading it.
    ///
    /// - Parameters:
    ///   - agentCommand: the command the agent was started with, for its quirks.
    ///   - maxMessageBytes: the longest line read from it, `nil` for no limit.
    /// - Throws: ``ChildProcess/SpawnError`` when it cannot be started.
    static func start(
        _ launch: ProcessLaunch, agentCommand: String, maxMessageBytes: Int?, tap: RawWireTap
    ) throws -> AgentProcessTransport {
        let process = try ChildProcess.spawn(
            command: launch.executable, arguments: launch.arguments,
            cwd: launch.workingDirectory ?? FileManager.default.currentDirectoryPath,
            environment: launch.environment, input: true, newSession: false)
        let transport = AgentProcessTransport(
            process: process, agentCommand: agentCommand, maxMessageBytes: maxMessageBytes,
            inheritStderr: launch.inheritStderr, tap: tap)
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
            onExit: { [self] status in exited(status) })
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

    /// Stop the transport: nothing more is sent, and the agent is ended in the
    /// background (see ``terminate()``, which a caller awaits to know it is over).
    /// Closing the connection is the first sign of the agent's end acpx sees when it
    /// closes a client — the process is still running — so it is `connection_close`.
    func close() {
        recordDisconnect(.connectionClose)
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

    /// Note the processes the agent has started so far — acpx looks once `initialize`
    /// is over — so they are ended with it even if it is gone by then and they have
    /// been handed to `init`.
    func captureDescendants() {
        descendantsLock.withLock { _ = descendants.capture(rootIsRunning: !process.hasBeenReaped) }
    }

    // MARK: - Reading

    /// acpx's `createNdJsonMessageStream` read side. Called on the reader thread.
    private func read(_ bytes: [UInt8]) {
        let lines: [AgentOutputReader.Line]
        do {
            lines = try reader.push(bytes)
        } catch {
            // acpx's `onReadError`: the requests waiting fail with the limit's error,
            // and the connection — then the agent — goes.
            process.stopReading()
            events.yield(.end(error))
            recordDisconnect(.connectionClose)
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
    }

    /// Stdout reached its end. The process exiting closes it too, and Node reports
    /// that exit before the pipe's close; the end is put down to the pipe only if the
    /// process is still running a moment later.
    private func stdoutClosed() {
        Task {
            if await waitForExit(timeout: .milliseconds(100)) { return }
            recordDisconnect(.pipeClose)
            // acpx's `handleAgentDisconnect`: an agent whose connection is gone is ended.
            _ = startTermination()
        }
    }

    /// A message could not be written: the agent closed its stdin. Unless the agent is
    /// exiting — as it usually is — that ends the connection, and the agent with it.
    private func writeFailed() {
        Task {
            if await waitForExit(timeout: .milliseconds(100)) { return }
            recordDisconnect(.connectionClose)
            _ = startTermination()
        }
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

    /// acpx's `recordAgentExit`: the first account of the agent's end wins, and the
    /// requests still waiting fail with it.
    private func recordDisconnect(_ reason: AgentDisconnectReason) {
        let recorded: AgentExit? = lock.withLock {
            guard lastExit == nil else { return nil }
            let exit = AgentExit(
                exitCode: exitStatus?.exitCode, signal: exitStatus?.signal, exitedAt: Self.now(), reason: reason,
                unexpectedDuringPrompt: !closing && !promptsInFlight.isEmpty)
            lastExit = exit
            return exit
        }
        guard let recorded else { return }
        writer.finish()
        events.yield(.end(AgentDisconnectedError(
            reason: recorded.reason, exitCode: recorded.exitCode, signal: recorded.signal)))
        events.finish()
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
        _ = await waitForExit(timeout: remaining(atMost: quirks.closeAfterStdinEnd))
        if await !signalAgentAndDescendants(SIGTERM, waiting: remaining(atMost: .milliseconds(1500))) {
            _ = await signalAgentAndDescendants(SIGKILL, waiting: remaining(atMost: .milliseconds(1000)))
        }
        descendantsLock.withLock { descendants.retire() }
        process.stopReading()
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

/// Writes the agent's messages to its stdin, in order, on a thread of its own — a write
/// waits while the agent does not read — and closes stdin once told to finish and the
/// queue is empty. Each body is shown to the tap as it is queued, in the sender's
/// context and in the order it is written.
private final class MessageWriter: @unchecked Sendable {
    private let process: ChildProcess
    private let tap: RawWireTap
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var queue: [Data] = []
    private var finishing = false
    /// Told, once, that a write failed. Set before ``start()``.
    var onFailure: (@Sendable () -> Void)?

    init(process: ChildProcess, tap: RawWireTap) {
        self.process = process
        self.tap = tap
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "acp.agent.stdin"
        thread.start()
    }

    /// Queue `body` to be written. Throws ``JSONRPCPeerError/closed`` once finishing.
    func enqueue(_ body: Data) throws {
        try lock.withLock {
            guard !finishing else { throw JSONRPCPeerError.closed }
            tap.observe(.outbound, body)
            queue.append(body)
        }
        available.signal()
    }

    /// Write what is queued, then close stdin — Node's `stdin.end()`.
    func finish() {
        let first: Bool = lock.withLock {
            defer { finishing = true }
            return !finishing
        }
        if first { available.signal() }
    }

    private func run() {
        var failed = false
        while true {
            available.wait()
            let (next, done): (Data?, Bool) = lock.withLock {
                queue.isEmpty ? (nil, finishing) : (queue.removeFirst(), false)
            }
            if let next {
                guard !failed else { continue }
                do {
                    try process.write(Array(next) + [0x0A])
                } catch {
                    // The agent closed its stdin — mostly by exiting, which is noticed
                    // on its own. What remains is not written.
                    failed = true
                    onFailure?()
                }
                continue
            }
            if done { break }
        }
        process.closeInput()
    }
}
#endif
