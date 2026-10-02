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
    /// The spec's `args ?? []` as the flow gave it (``FlowShellExecution/rawArgs``).
    let args: [WireJSON]
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
            ("command", .text(command)), ("args", .array(args)), ("cwd", .text(cwd)),
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

/// acpx's `src/flows/executors/shell.ts` (v0.19.4): a command run for a shell action, or
/// for a function action's `ctx.runShell`, in a session of its own — Node's `detached` —
/// its pipes read as Node's `setEncoding("utf8")` reads them.
enum FlowShellProcess {
    /// A shell action's command resolves when the process exits, its pipes given up to
    /// 100 ms more to close (acpx's `"node"` mode); `ctx.runShell`'s once its pipes have
    /// closed (`"command"`).
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
        let timeoutMs = try FlowShell.resolveTimeout(spec.timeoutMs).map(FlowShell.timerDelayMs)
        try FlowShell.validateMaxBufferBytes(spec.maxBufferBytes)
        // acpx: `if (spec.stdin !== undefined && typeof spec.stdin !== "string") throw new
        // TypeError(…)` — `null`, a number, an object and a Buffer alike, before anything is
        // started (openclaw/acpx#811). `undefined` is no member of the spec the host sent.
        if let stdin = spec.stdin, stdin.stringValue == nil {
            throw FlowShellError("stdin must be a string", name: "TypeError")
        }
        let spawn = try spec.spawnPlan(cwd: cwd, inheriting: FlowShellExecution.processEnvironment)
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(
                command: spawn.file, arguments: spawn.arguments,
                cwd: spawn.cwd ?? FileManager.default.currentDirectoryPath, orderedEnvironment: spawn.environment,
                input: true, newSession: spawn.newSession)
        } catch let error as ChildSpawn.SpawnError {
            throw FlowShellSpawnError(file: spawn.file, arguments: spawn.arguments, code: error.code)
        }
        let closed = FlowShellEvent()
        var termination: FlowShellTermination?
        let outcome: Result<FlowShellResult, Error>
        do {
            let result: FlowShellResult = try await withCheckedThrowingContinuation { continuation in
                let first = FirstResult(continuation)
                let stopper = FlowShellTermination(
                    pid: child.pid, closed: closed, timeoutMs: timeoutMs, control: control,
                    onCleanupFailure: { first.settle(.failure($0)) })
                termination = stopper
                let run = FlowShellRun(
                    spec: spec, args: spec.rawArgs, cwd: cwd, startMs: startMs, mode: mode, closed: closed,
                    termination: stopper, first: first)
                child.start(
                    onChunk: { run.chunk($0, $1) }, onClose: { run.streamClosed($0) }, onExit: { run.exited($0) })
                writeStdin(child, spec.stdin?.stringValue)
            }
            try throwIfCancelled(control.attempt, mode: mode)
            outcome = .success(result)
        } catch {
            // acpx's `catch (error) { await termination.cancel("SIGTERM"); throw error; }`: a
            // command that failed on its way out is stopped, and the stop — the one under
            // way, for an attempt cancelled — waited for before the failure is reported; a
            // stop that fails is the failure (openclaw/acpx#811).
            var failure = error
            do {
                try await termination?.cancel("SIGTERM")
            } catch let stopping {
                failure = stopping
            }
            outcome = .failure(failure)
        }
        try await termination?.dispose()
        return try outcome.get()
    }

    /// acpx's `writeShellStdin`: the string the spec gives as UTF-8, written on a thread of
    /// its own, as Node writes without waiting, then the pipe's end. A child that closed it
    /// early is no matter, its exit tells.
    private static func writeStdin(_ child: ChildProcess, _ stdin: String?) {
        guard let stdin else {
            child.closeInput()
            return
        }
        Thread {
            try? child.write(Array(stdin.utf8))
            child.closeInput()
        }.start()
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
/// once it closes (`runShell`) — or, for a shell action, once it exits and its pipes have
/// closed or ``drainWindow`` has passed since: what the wrapper wrote last is drained,
/// while a descendant that inherited the pipes does not hold the step (openclaw/acpx#813).
/// Output past the capture limit fails it and stops the tree.
final class FlowShellRun: @unchecked Sendable {
    /// acpx's 100 ms `drainDeadline` after a shell action's exit; a test may lengthen it.
    @TaskLocal static var drainWindow: Duration = .milliseconds(100)

    /// Where the drain's deadline fires: not the cooperative pool, which a busy machine can
    /// hold past it.
    private static let drains = DispatchQueue(label: "acpx.flow.shell.drain")

    private let spec: FlowShellExecution
    private let args: [WireJSON]
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
    /// The drain's deadline, armed at a shell action's exit until it closes or settles.
    private var drainDeadline: DispatchWorkItem?
    private let drainWindow = FlowShellRun.drainWindow
    /// For tests: how long the exit takes to be taken in past its first step (``FlowShellTermination/exitIsTakenInLateBy``).
    private let exitIsTakenInLateBy = FlowShellTermination.exitIsTakenInLateBy

    init(
        spec: FlowShellExecution, args: [WireJSON], cwd: String, startMs: Int64, mode: FlowShellProcess.Mode,
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
        let stopper = termination
        Task {
            do {
                try await stopper.cancel("SIGTERM")
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

    /// Node's `exit`. A shell action's deadline goes first, as its exit is taken in: a
    /// command that exited in time has not timed out, though its drain is still to come —
    /// acpx's timer, cleared only with the result, can fire within it (#220 review). Its
    /// result follows at `close`, or ``drainWindow`` after the exit, whichever comes first
    /// (acpx's `drainDeadline`, openclaw/acpx#813).
    func exited(_ status: Int32?) {
        if mode == .node { termination.resultIsIn() }
        if let late = exitIsTakenInLateBy { Thread.sleep(forTimeInterval: Double(late / .milliseconds(1)) / 1000) }
        let drain: DispatchWorkItem? = lock.withLock {
            hasExited = true
            self.status = status
            guard mode == .node, !settled, closedStreams < 2 else { return nil }
            // Held by its deadline, as acpx's promise is by its timer, until it fires or is cancelled.
            let deadline = DispatchWorkItem { self.finish() }
            drainDeadline = deadline
            return deadline
        }
        if let drain {
            Self.drains.asyncAfter(deadline: .now() + .nanoseconds(Int(drainWindow / .nanoseconds(1))), execute: drain)
        }
        checkClosed()
    }

    /// Node's `close`: exited, and both pipes at their end — the result, `runShell`'s
    /// deadline gone as it is taken in.
    private func checkClosed() {
        let closedNow: Bool = lock.withLock { hasExited && closedStreams == 2 && !closed.hasHappened }
        guard closedNow else { return }
        if mode == .command { termination.resultIsIn() }
        closed.fire()
        termination.handleClose()
        finish()
    }

    /// acpx's `finish`: the result, once; the drain's deadline is no more.
    private func finish() {
        let drain: DispatchWorkItem? = lock.withLock {
            defer { drainDeadline = nil }
            return drainDeadline
        }
        drain?.cancel()
        settle()
    }

    /// The result, with whether the command was stopped — and for its deadline — as acpx
    /// reads both when it resolves.
    private func settle() {
        let stopped = termination.stopped
        let result: FlowShellResult? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            let exit = ChildProcess.exitStatus(status)
            return FlowShellResult(
                command: spec.command ?? "", args: args, cwd: cwd, stdout: capture.stdout, stderr: capture.stderr,
                exitCode: exit.exitCode, signal: exit.signal, durationMs: Double(FlowShellClock.nowMs() - startMs),
                timedOut: mode == .node ? stopped.cancelled : stopped.timedOut)
        }
        if let result { first.settle(.success(result)) }
    }

    private func fail(_ error: Error) {
        let drain: DispatchWorkItem? = lock.withLock {
            settled = true
            defer { drainDeadline = nil }
            return drainDeadline
        }
        drain?.cancel()
        first.settle(.failure(error))
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
