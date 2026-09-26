import ACPXCore
import Foundation
import SwiftACP

#if canImport(Darwin)
import Darwin
#endif

/// acpx's `ShellProcessOwner`: what stops a command's tree — for the attempt it runs for,
/// or for the run when it is interrupted — and what lets it go.
struct FlowShellOwner: Sendable {
    let cancel: @Sendable (_ signal: String) async throws -> Void
    let release: @Sendable () -> Void
}

/// acpx's `RunShellActionOptions`: the attempt a command runs for — whose cancellation
/// stops it, with the attempt's termination signal — and who else keeps hold of it.
struct FlowShellControl: Sendable {
    var attempt: FlowAttempt?
    var registerOwner: (@Sendable (FlowShellOwner) -> @Sendable () -> Void)?
}

/// What a command came to: acpx's `ShellActionResult`, and `runShell`'s `FlowShellResult`
/// with `timedOut`.
struct FlowShellResult: Sendable {
    let command: String
    let args: [String]
    let cwd: String
    let stdout: String
    let stderr: String
    let exitCode: Int?
    let signal: String?
    let durationMs: Double
    let timedOut: Bool

    var combinedOutput: String { stdout + stderr }

    /// The result as acpx's object is written, `timedOut` last when it has one.
    func wire(timedOut includeTimedOut: Bool) -> WireJSON {
        var members: [(String, WireJSON?)] = [
            ("command", .text(command)), ("args", .array(args.map(WireJSON.text))), ("cwd", .text(cwd)),
            ("stdout", .text(stdout)), ("stderr", .text(stderr)), ("combinedOutput", .text(combinedOutput)),
            ("exitCode", exitCode.map { .number(Double($0)) } ?? .null), ("signal", signal.map(WireJSON.text) ?? .null),
            ("durationMs", .number(durationMs))
        ]
        if includeTimedOut { members.append(("timedOut", .bool(timedOut))) }
        return .object(members)
    }
}

/// A command that could not be started, as Node's `spawn` reports it: `spawn sh ENOENT`.
struct FlowShellSpawnError: Error, LocalizedError {
    let file: String
    /// The arguments after the file: Node's `spawnargs`.
    let arguments: [String]
    let code: Int32
    var errorDescription: String? { "spawn \(file) \(ChildSpawn.SpawnError(code: code).name)" }
}

/// acpx's `src/flows/executors/shell.ts` (v0.19.3): a command run for a shell action, or
/// for a function action's `ctx.runShell`, in a session of its own — Node's `detached` —
/// its pipes read as Node's `setEncoding("utf8")` reads them.
enum FlowShellProcess {
    /// A shell action's command resolves when the process exits (acpx's `"node"` mode);
    /// `ctx.runShell`'s once its pipes have closed too (`"command"`).
    enum Mode: Sendable {
        case node
        case command
    }

    /// acpx's `runShellAction`: the command's result, or — past its deadline, cancelled,
    /// or failed and not allowed to — the error acpx fails the step with.
    static func runAction(_ spec: FlowShellExecution, cwd: String, control: FlowShellControl) async throws
        -> FlowShellResult {
        let result = try await run(spec, cwd: cwd, control: control, mode: .node)
        if result.timedOut { throw FlowShell.timeoutError(spec) }
        if (result.exitCode ?? 0) != 0 || result.signal != nil, !spec.allowNonZeroExit {
            throw FlowShellError(FlowShell.failureMessage(
                command: result.command, args: result.args, exitCode: result.exitCode, signal: result.signal,
                stderr: result.stderr))
        }
        return result
    }

    /// acpx's `runShellCommand`: `ctx.runShell`'s command, which reports a failing exit
    /// rather than failing on it.
    static func runCommand(_ spec: FlowShellExecution, cwd: String, control: FlowShellControl) async throws
        -> FlowShellResult {
        try await run(spec, cwd: cwd, control: control, mode: .command)
    }

    /// acpx's `runShellProcess`.
    static func run(_ spec: FlowShellExecution, cwd: String, control: FlowShellControl, mode: Mode) async throws
        -> FlowShellResult {
        if let reason = control.attempt?.abortReason { throw reason }
        let startMs = FlowShellClock.nowMs()
        let timeoutMs = FlowShell.resolveTimeout(spec.timeoutMs).map(FlowShell.timerDelayMs)
        try FlowShell.validateMaxBufferBytes(spec.maxBufferBytes)
        let (file, arguments) = try spec.spawnArguments()
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(
                command: file, arguments: arguments, cwd: cwd,
                environment: spec.environment(inheriting: ProcessInfo.processInfo.environment),
                input: true, newSession: true)
        } catch let error as ChildSpawn.SpawnError {
            throw FlowShellSpawnError(file: file, arguments: arguments, code: error.code)
        }
        let closed = FlowShellEvent()
        var termination: FlowShellTermination?
        let outcome: Result<FlowShellResult, Error>
        do {
            let result: FlowShellResult = try await withCheckedThrowingContinuation { continuation in
                let first = FirstResult(continuation)
                let stopper = FlowShellTermination(
                    child: child, closed: closed, timeoutMs: timeoutMs, control: control,
                    onCleanupFailure: { first.settle(.failure($0)) })
                termination = stopper
                let run = FlowShellRun(
                    spec: spec, args: spec.args, cwd: cwd, startMs: startMs, mode: mode, closed: closed,
                    termination: stopper, first: first)
                child.start(
                    onChunk: { run.chunk($0, $1) }, onClose: { run.streamClosed($0) }, onExit: { run.exited($0) })
                do {
                    try writeStdin(child, spec.stdin)
                } catch {
                    first.settle(.failure(error))
                    Task { try? await stopper.cancel("SIGTERM") }
                }
            }
            try throwIfCancelled(control.attempt, mode: mode)
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        try await termination?.dispose()
        return try outcome.get()
    }

    /// acpx's `writeShellStdin`: what the spec gives, then the pipe's end — a child that
    /// closed it early is no matter, its exit tells. Written on a thread of its own, as
    /// Node writes without waiting.
    private static func writeStdin(_ child: ChildProcess, _ stdin: WireJSON?) throws {
        switch stdin {
        case nil, .null?:
            child.closeInput()
        case .string(let units)?:
            let bytes = Array(String(decoding: units, as: UTF16.self).utf8)
            Thread {
                try? child.write(bytes)
                child.closeInput()
            }.start()
        case let other?:
            child.closeInput()
            throw FlowShellError.invalidArgType(NodeArgumentError.type(
                "chunk", "of type string or an instance of Buffer, TypedArray, or DataView", other))
        }
    }

    /// acpx's `throwIfShellCancelled`: an attempt cancelled while the command ran fails
    /// `runShell` with its reason; a shell action only when that is a timeout or an
    /// interrupt — any other reads as the command having timed out.
    private static func throwIfCancelled(_ attempt: FlowAttempt?, mode: Mode) throws {
        guard let reason = attempt?.abortReason else { return }
        if mode == .command || reason is FlowTimeoutError || reason is FlowInterruptedError { throw reason }
    }
}

/// acpx's `waitForShellResult`: the command's output captured as it comes, and its result
/// once it exits (a shell action) or closes (`runShell`). Output past the capture limit
/// fails it and stops the tree.
private final class FlowShellRun: @unchecked Sendable {
    private let spec: FlowShellExecution
    private let args: [String]
    private let cwd: String
    private let startMs: Int64
    private let mode: FlowShellProcess.Mode
    private let closed: FlowShellEvent
    private let termination: FlowShellTermination
    private let first: FirstResult<FlowShellResult>
    private let lock = NSLock()
    private var capture: FlowShellCapture
    private var settled = false
    private var status: Int32?
    private var hasExited = false
    private var closedStreams = 0

    init(
        spec: FlowShellExecution, args: [String], cwd: String, startMs: Int64, mode: FlowShellProcess.Mode,
        closed: FlowShellEvent, termination: FlowShellTermination, first: FirstResult<FlowShellResult>
    ) {
        self.spec = spec
        self.args = args
        self.cwd = cwd
        self.startMs = startMs
        self.mode = mode
        self.closed = closed
        self.termination = termination
        self.first = first
        capture = FlowShellCapture(maxBufferBytes: spec.maxBufferBytes)
    }

    func chunk(_ output: ChildProcess.Output, _ bytes: [UInt8]) {
        let overflow: FlowShellError? = lock.withLock {
            // Once settled — or, for a shell action, once it is being stopped — nothing more
            // is kept.
            if settled || (mode == .node && termination.cancelled) { return nil }
            return capture.append(output == .stdout ? .stdout : .stderr, bytes)
        }
        guard let overflow, !termination.cancelled else { return }
        fail(overflow)
        let termination = self.termination
        Task {
            do {
                try await termination.cancel("SIGTERM")
            } catch {
                self.fail(error)
            }
        }
    }

    func streamClosed(_ output: ChildProcess.Output) {
        let overflow: FlowShellError? = lock.withLock {
            closedStreams += 1
            // Node's decoder ends with the stream, before `close`.
            guard !settled else { return nil }
            return capture.end(output == .stdout ? .stdout : .stderr)
        }
        if let overflow, !termination.cancelled { fail(overflow) }
        checkClosed()
    }

    func exited(_ status: Int32?) {
        lock.withLock {
            hasExited = true
            self.status = status
        }
        if mode == .node { settle() }
        checkClosed()
    }

    /// Node's `close`: exited, and both pipes at their end.
    private func checkClosed() {
        let closedNow: Bool = lock.withLock { hasExited && closedStreams == 2 && !closed.hasHappened }
        guard closedNow else { return }
        closed.fire()
        termination.handleClose()
        if mode == .command { settle() }
    }

    private func settle() {
        let result: FlowShellResult? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            let exit = ChildProcess.exitStatus(status)
            return FlowShellResult(
                command: spec.command ?? "", args: args, cwd: cwd, stdout: capture.stdout, stderr: capture.stderr,
                exitCode: exit.exitCode, signal: exit.signal, durationMs: Double(FlowShellClock.nowMs() - startMs),
                timedOut: mode == .node ? termination.cancelled : termination.timedOut)
        }
        if let result { first.settle(.success(result)) }
    }

    private func fail(_ error: Error) {
        lock.withLock { settled = true }
        first.settle(.failure(error))
    }
}

/// acpx's `createShellTermination`: what stops a command's tree — at its deadline, when
/// its attempt is cancelled, or for an owner — once, then lets it go. While an owner keeps
/// it, a command that closed with processes left in its group stays kept until they are
/// gone, so an interrupt still reaches them.
final class FlowShellTermination: @unchecked Sendable {
    private let child: ChildProcess
    private let closed: FlowShellEvent
    private let onCleanupFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var stopping: Task<Void, Error>?
    private var timedOutFlag = false
    private var cancelledFlag = false
    private var released = false
    private var deadline: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var unregister: (@Sendable () -> Void)?
    private var removeAbortListener: (() -> Void)?
    private var hasOwner = false

    init(
        child: ChildProcess, closed: FlowShellEvent, timeoutMs: Double?, control: FlowShellControl,
        onCleanupFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.child = child
        self.closed = closed
        self.onCleanupFailure = onCleanupFailure
        if let attempt = control.attempt {
            let listening = attempt.addAbortListener { [self] _ in
                Task { try? await self.cancel(attempt.terminationSignal) }
            }
            if let listening {
                removeAbortListener = listening
            } else {
                Task { try? await self.cancel(attempt.terminationSignal) }
            }
        }
        if let delay = timeoutMs.flatMap(FlowTimer.duration(milliseconds:)) {
            deadline = Task { [self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                lock.withLock { timedOutFlag = true }
                try? await cancel("SIGTERM")
            }
        }
        if let registerOwner = control.registerOwner {
            hasOwner = true
            unregister = registerOwner(FlowShellOwner(
                cancel: { [self] signal in try await cancel(signal) }, release: { [self] in release() }))
        }
    }

    var timedOut: Bool { lock.withLock { timedOutFlag } }
    var cancelled: Bool { lock.withLock { cancelledFlag } }

    /// Stop the tree with `signal`, or wait for the stop under way.
    func cancel(_ signal: String) async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if let stopping { return stopping }
            guard !released else { return nil }
            deadline?.cancel()
            cancelledFlag = true
            let number = FlowShellSignals.number(signal)
            let (pid, closed, onCleanupFailure) = (child.pid, self.closed, self.onCleanupFailure)
            let task = Task { [self] in
                defer { release() }
                do {
                    try await FlowShellTree.stop(pid, signal: number, closed: closed)
                } catch {
                    onCleanupFailure(error)
                    throw error
                }
            }
            stopping = task
            return task
        }
        try await task?.value
    }

    /// The command closed: kept by an owner, it stays kept while its group has processes.
    func handleClose() {
        let start: Bool = lock.withLock { hasOwner && !released && stopping == nil }
        guard start else { return }
        let pid = child.pid
        let watching = Task { [self] in
            while !Task.isCancelled {
                let idle = lock.withLock { stopping == nil }
                if idle, !FlowShellTree.hasProcesses(pid) {
                    release()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        lock.withLock { monitor = watching }
    }

    /// acpx's `dispose`: no deadline any more, the stop under way waited for, and — kept
    /// by no one — let go.
    func dispose() async throws {
        let task: Task<Void, Error>? = lock.withLock {
            deadline?.cancel()
            return stopping
        }
        defer { if !hasOwner { release() } }
        try await task?.value
    }

    /// acpx's `release`.
    func release() {
        let (listening, unregistering): ((() -> Void)?, (@Sendable () -> Void)?) = lock.withLock {
            guard !released else { return (nil, nil) }
            released = true
            deadline?.cancel()
            monitor?.cancel()
            defer {
                removeAbortListener = nil
                unregister = nil
            }
            return (removeAbortListener, unregister)
        }
        listening?()
        unregistering?()
    }
}

/// Signal names, as Node's `process.kill` takes them.
enum FlowShellSignals {
    static func number(_ name: String) -> Int32 {
        ChildSpawn.signalNames.first { $0.value == name }?.key ?? SIGTERM
    }
}

/// `Date.now()`.
enum FlowShellClock {
    static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
