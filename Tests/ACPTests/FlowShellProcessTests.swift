@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// acpx's `runShellAction` and `runShellCommand` (`test/flows-shell.test.ts`, v0.19.3):
/// commands run in a session of their own, their output captured, their trees stopped.
struct FlowShellProcessTests {
    static let node = AgentRegistry.which("node")

    private func spec(_ members: [(String, WireJSON?)]) -> FlowShellExecution {
        FlowShellExecution(json: .object(members))
    }

    private func nodeSpec(_ script: String, _ more: [(String, WireJSON?)] = []) throws -> FlowShellExecution {
        let node = try #require(Self.node)
        return spec([("command", .text(node)), ("args", .array([.text("-e"), .text(script)]))] + more)
    }

    private func runAction(
        _ spec: FlowShellExecution, control: FlowShellControl = FlowShellControl()
    ) async throws -> FlowShellResult {
        try await FlowShellProcess.runAction(spec, cwd: NSTemporaryDirectory(), control: control)
    }

    /// acpx: "runShellAction captures stdout and stderr".
    @Test(.enabled(if: node != nil))
    func stdoutAndStderrAreCaptured() async throws {
        let result = try await runAction(nodeSpec(#"process.stdout.write("ok"); process.stderr.write("warn");"#))
        #expect(result.stdout == "ok")
        #expect(result.stderr == "warn")
        #expect(result.combinedOutput == "okwarn")
        #expect(result.exitCode == 0)
        #expect(result.signal == nil)
    }

    /// acpx: "runShellAction allows non-zero exits when requested" and "rejects non-zero
    /// exits by default".
    @Test(.enabled(if: node != nil))
    func aFailingExitFailsUnlessAllowed() async throws {
        let allowed = try await runAction(nodeSpec("process.exit(3)", [("allowNonZeroExit", .bool(true))]))
        #expect(allowed.exitCode == 3)
        let script = #"process.stderr.write("boom"); process.exit(2)"#
        let error = await #expect(throws: FlowShellError.self) { _ = try await self.runAction(self.nodeSpec(script)) }
        let rendered = try FlowShell.renderCommand(try #require(Self.node), [.text("-e"), .text(script)])
        #expect(error?.message == "Shell action failed (\(rendered)): exit 2\nboom")
    }

    /// acpx: "runShellAction times out long-running commands" and "treats timeoutMs 0 as
    /// no deadline".
    @Test(.enabled(if: node != nil))
    func onlyAPositiveTimeoutStopsTheCommand() async throws {
        await #expect(throws: FlowTimeoutError(timeoutMs: 50)) {
            _ = try await self.runAction(self.nodeSpec("setTimeout(() => {}, 10_000)", [("timeoutMs", .number(50))]))
        }
        let started = ContinuousClock.now
        let result = try await runAction(nodeSpec("setTimeout(() => {}, 80)", [("timeoutMs", .number(0))]))
        #expect(result.exitCode == 0)
        #expect(ContinuousClock.now - started >= .milliseconds(70))
    }

    /// A deadline that passes while the cooperative pool has no thread free for the
    /// command's stop still times the command out, as acpx's timer does on its event loop.
    /// On CI's busy runner the deadline once ran only after the command had exited, and a
    /// command 10 s past its 50 ms deadline read as finished.
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func aDeadlinePassingWhileThePoolIsBusyStillTimesTheCommandOut() async throws {
        let started = ContinuousClock.now
        await FlowShellTermination.$poolIsBusy.withValue(true) {
            await #expect(throws: FlowTimeoutError(timeoutMs: 50)) {
                _ = try await self.runAction(self.nodeSpec("setTimeout(() => {}, 1000)", [("timeoutMs", .number(50))]))
            }
        }
        // Its stop waited for the result: the command ran until it exited on its own.
        #expect(ContinuousClock.now - started >= .milliseconds(1000))
    }

    /// A command's deadline that its attempt gave it — the rest of a shell node's time — is
    /// no earlier than the attempt's own, whose timer acpx sets first and fires first: the
    /// step fails with the node's timeout. With the attempt's timer late on a busy pool, the
    /// command's deadline times the attempt out before it does the command.
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func anAttemptsDeadlineComesBeforeItsCommandsHoweverLateItsTimer() async throws {
        let attempt = FlowAttempt.$timerIsLate.withValue(true) {
            FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: 50)
        }
        await #expect(throws: FlowTimeoutError(timeoutMs: 50)) {
            _ = try await self.runAction(
                self.nodeSpec("setTimeout(() => {}, 10_000)", [("timeoutMs", .number(100))]),
                control: FlowShellControl(attempt: attempt))
        }
    }

    /// A command's own deadline earlier than its attempt's is the one it fails with, as
    /// acpx's timer for it fires first — however late it fires here, after the attempt's
    /// deadline has passed as well. (The attempt's deadline stays the later one as long as
    /// the command starts within 1.95 s of the attempt; its timer, 2 s late, fires after it.)
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func aCommandsEarlierDeadlineStaysItsOwnHoweverLateItsTimer() async throws {
        let attempt = FlowAttempt.$timerIsLate.withValue(true) {
            FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: 2000)
        }
        await FlowShellTermination.$timerIsLateBy.withValue(.milliseconds(2000)) {
            await #expect(throws: FlowTimeoutError(timeoutMs: 50)) {
                _ = try await self.runAction(
                    self.nodeSpec("setTimeout(() => {}, 10_000)", [("timeoutMs", .number(50))]),
                    control: FlowShellControl(attempt: attempt))
            }
        }
    }

    /// A command that exits before its deadline keeps what it left running in its group, though
    /// the task awaiting its result gets to dispose of it only past the deadline — on a busy
    /// pool — as acpx's deadline goes with the result, before its timer can fire (#220 review).
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func aCommandDoneBeforeItsDeadlineKeepsWhatItLeftRunning() async throws {
        let fifo = try FIFOReader.make(name: "left running")
        let descendant = "require('node:fs').writeFileSync(\(fifo.jsPath),String(process.pid));setInterval(()=>{},1000)"
        let wrapper = "require('node:child_process').spawn(process.execPath,"
            + "['-e',\(WireJSON.text(descendant).stringified)],{stdio:'ignore'}).unref()"
        let running = Task {
            try await FlowShellTermination.$disposeIsLateBy.withValue(.milliseconds(300)) {
                try await self.runAction(self.nodeSpec(wrapper, [("timeoutMs", .number(3000))]))
            }
        }
        let pid = try #require(pid_t(await fifo.next()))
        defer { if isAlive(pid) { kill(pid, SIGKILL) } }
        let result = try await running.value
        #expect(!result.timedOut)
        #expect(isAlive(pid), "descendant \(pid) was stopped with a command done in time")
    }

    /// A shell action that exits before its deadline has finished, though the deadline passes
    /// while its exit is still being taken in: the deadline goes as the exit is first seen, as
    /// acpx takes the exit in one callback its timer cannot come between (#220 review).
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func anExitSeenBeforeTheDeadlineStands() async throws {
        let result = try await FlowShellTermination.$exitIsTakenInLateBy.withValue(.milliseconds(2500)) {
            try await self.runAction(self.nodeSpec("", [("timeoutMs", .number(2000))]))
        }
        #expect(!result.timedOut)
    }

    /// acpx: "runShellAction rejects commands terminated by signal".
    @Test func aCommandEndedBySignalFails() async throws {
        let error = await #expect(throws: FlowShellError.self) {
            _ = try await self.runAction(self.spec([
                ("command", .text("/bin/sh")), ("args", .array([.text("-c"), .text(#"kill -TERM "$$""#)]))
            ]))
        }
        #expect(error?.message.hasSuffix(": signal SIGTERM") == true, "\(error?.message ?? "")")
    }

    /// acpx: "shell input and deadlines are validated before spawning" (openclaw/acpx#811,
    /// openclaw/acpx#812): a `stdin` that is no string — a number, an object, `null`, a Buffer —
    /// and a `timeoutMs` past Node's timer limit, `Infinity` or `NaN` are refused with acpx's
    /// `TypeError` before anything is started: the command, run, would leave a mark. A string
    /// is written as before.
    @Test func stdinAndDeadlinesAreCheckedBeforeTheSpawn() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-shell-admission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let touch: [(String, WireJSON?)] = [
            ("command", .text("/bin/sh")), ("args", .array([.text("-c"), .text("touch \(marker.path)")]))
        ]
        let command = { (more: [(String, WireJSON?)]) in
            try await FlowShellProcess.runCommand(
                self.spec(touch + more), cwd: NSTemporaryDirectory(), control: FlowShellControl())
        }
        let buffer: WireJSON = .object([
            (FlowJS.markerKey, .text("instance")), ("text", .text("an instance of Buffer")), ("string", .text("hi")),
            ("json", .object([("type", .text("Buffer")), ("data", .array([.number(104), .number(105)]))]))
        ])
        for stdin in [.number(5), .object([WireJSON.Member]()), .null, buffer] as [WireJSON] {
            let error = await #expect(throws: FlowShellError.self, "\(stdin)") {
                _ = try await command([("stdin", stdin)])
            }
            #expect(error?.message == "stdin must be a string", "\(stdin)")
            #expect(error?.name == "TypeError", "\(stdin)")
        }
        let nonFinite = { (text: String) in
            WireJSON.object([(FlowJS.markerKey, .text("number")), ("text", .text(text))])
        }
        for timeoutMs in [.number(2_147_483_648), nonFinite("Infinity"), nonFinite("NaN")] as [WireJSON] {
            let error = await #expect(throws: FlowTimerLimitError.self, "\(timeoutMs)") {
                _ = try await command([("timeoutMs", timeoutMs)])
            }
            #expect(error?.localizedDescription == "timeoutMs must be a finite number no greater than 2147483647")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a refused command was started")
        let written = try await FlowShellProcess.runCommand(
            spec([("command", .text("/bin/cat")), ("stdin", .text("hi"))]), cwd: NSTemporaryDirectory(),
            control: FlowShellControl())
        #expect(written.stdout == "hi")
    }

    /// acpx: "runShellAction does not crash the host when the child exits before reading
    /// stdin".
    @Test(.enabled(if: node != nil))
    func aChildThatLeavesItsStdinUnreadIsNoMatter() async throws {
        let result = try await runAction(nodeSpec("setImmediate(() => process.exit(0))", [
            ("stdin", .text(String(repeating: "x", count: 1024 * 1024))), ("allowNonZeroExit", .bool(true))
        ]))
        #expect(result.exitCode == 0)
        #expect(result.signal == nil)
    }

    /// acpx: "runShellAction reaps child when abort signal fires": an attempt cancelled
    /// for another reason than a timeout or an interrupt reads as the command timing out.
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func aCancelledAttemptStopsItsCommand() async throws {
        let fifo = try FIFOReader.make()
        let attempt = FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: nil)
        let pending = Task {
            try await self.runAction(
                self.nodeSpec(
                    "require('node:fs').writeFileSync(\(fifo.jsPath), String(process.pid));"
                        + "setTimeout(() => {}, 30_000)"),
                control: FlowShellControl(attempt: attempt))
        }
        let pid = try #require(pid_t(await fifo.next()))
        attempt.cancel(FlowShellError("stop"))
        await #expect(throws: FlowTimeoutError(timeoutMs: 0)) { _ = try await pending.value }
        #expect(!isAlive(pid))
    }

    /// An attempt cancelled while the pool has no thread free marks its command stopped at
    /// once, as acpx's abort listener does: a command that then exits on its own, before
    /// its stop can run, still reads as having timed out.
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func anAttemptCancelledWhileThePoolIsBusyStillTimesTheCommandOut() async throws {
        let fifo = try FIFOReader.make()
        let attempt = FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: nil)
        let script = "process.on('SIGUSR2', () => process.exit(0));"
            + "require('node:fs').writeFileSync(\(fifo.jsPath), String(process.pid)); setInterval(() => {}, 1000)"
        try await FlowShellTermination.$poolIsBusy.withValue(true) {
            let pending = Task {
                try await self.runAction(self.nodeSpec(script), control: FlowShellControl(attempt: attempt))
            }
            let pid = try #require(pid_t(await fifo.next()))
            attempt.cancel(FlowShellError("stop"))
            // The command ends on its own, its stop still waiting for the pool.
            kill(pid, SIGUSR2)
            await #expect(throws: FlowTimeoutError(timeoutMs: 0)) { _ = try await pending.value }
        }
    }

    /// acpx: "shell abort stops descendants after wrapper exit": a descendant that ignores
    /// SIGTERM, in the command's group or in a session of its own, is killed as well.
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)), arguments: [false, true])
    func stoppingACommandStopsWhatItStarted(_ detached: Bool) async throws {
        let node = try #require(Self.node)
        let fifo = try FIFOReader.make(name: "descendant space & $dollar 'quote'")
        let descendant = "process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(\(fifo.jsPath),"
            + "String(process.pid));setInterval(()=>{},1000)"
        let wrapper = "require('node:child_process').spawn(process.execPath,"
            + "['-e',\(WireJSON.text(descendant).stringified)],"
            + "{stdio:'ignore',detached:\(detached)});setInterval(()=>{},1000)"
        let wrapperFile = fifo.directory.appendingPathComponent("wrapper.cjs")
        try wrapper.write(to: wrapperFile, atomically: true, encoding: .utf8)
        let attempt = FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: nil)
        let pending = Task {
            try await self.runAction(self.spec([
                ("command", .text(#""$ACPX_TEST_NODE" "$ACPX_TEST_WRAPPER""#)),
                ("env", .object([("ACPX_TEST_NODE", .text(node)), ("ACPX_TEST_WRAPPER", .text(wrapperFile.path))])),
                ("shell", .bool(true)), ("timeoutMs", .number(0))
            ]), control: FlowShellControl(attempt: attempt))
        }
        let pid = try #require(pid_t(await fifo.next()))
        attempt.cancel(FlowShellError("stop"))
        await #expect(throws: FlowTimeoutError.self) { _ = try await pending.value }
        #expect(!isAlive(pid), "descendant \(pid) is still running")
        if isAlive(pid) { kill(pid, SIGKILL) }
    }

    /// acpx: "shell cancellation before launch preserves the cancellation reason".
    @Test func aCommandForACancelledAttemptIsNeverStarted() async throws {
        let attempt = FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: nil)
        attempt.cancel(FlowTimeoutError(timeoutMs: 10))
        await #expect(throws: FlowTimeoutError(timeoutMs: 10)) {
            _ = try await self.runAction(
                self.spec([("command", .text("this-must-not-be-spawned"))]),
                control: FlowShellControl(attempt: attempt))
        }
    }

    /// acpx: "shell spawn errors remain authoritative with cancellation enabled".
    @Test func aCommandThatCannotStartFailsAsNodeSays() async throws {
        let attempt = FlowAttempt(nodeId: "shell", attemptId: "shell#1", startedAt: "", timeoutMs: nil)
        let error = await #expect(throws: FlowShellSpawnError.self) {
            _ = try await self.runAction(
                self.spec([("command", .text("/nonexistent/acpx-shell-proof"))]),
                control: FlowShellControl(attempt: attempt))
        }
        #expect(error?.localizedDescription == "spawn /nonexistent/acpx-shell-proof ENOENT")
    }

    /// acpx: "shell capture stays unlimited by default and limits streams independently",
    /// "rejects excess stdout and stderr even when nonzero exits are allowed", "counts split
    /// UTF-8 characters" and "rejects invalid limits before spawning".
    @Test(.enabled(if: node != nil))
    func theCaptureLimitHoldsForEachStream() async throws {
        let unlimited = try await runAction(nodeSpec(#"process.stdout.write("x".repeat(2*1024*1024))"#))
        #expect(unlimited.stdout.utf8.count == 2 * 1024 * 1024)
        let bounded = try await runAction(nodeSpec(#"process.stdout.write("aaaa");process.stderr.write("bbbb")"#, [
            ("maxBufferBytes", .number(4))
        ]))
        #expect(bounded.combinedOutput == "aaaabbbb")
        let empty = try await runAction(nodeSpec("", [("maxBufferBytes", .number(0))]))
        #expect(empty.combinedOutput.isEmpty)
        for stream in ["stdout", "stderr"] {
            let error = await #expect(throws: FlowShellError.self) {
                _ = try await self.runAction(self.nodeSpec("process.\(stream).write(\"12345\")", [
                    ("maxBufferBytes", .number(4)), ("allowNonZeroExit", .bool(true))
                ]))
            }
            #expect(error?.message == "Shell action exceeded maxBuffer (4 bytes) on \(stream)")
        }
        let split = "process.stdout.write(Buffer.from([0xc3]));"
            + "setTimeout(()=>process.stdout.write(Buffer.from([0xa9])),20)"
        #expect(try await runAction(nodeSpec(split, [("maxBufferBytes", .number(2))])).stdout == "é")
        await #expect(throws: FlowShellError.self) {
            _ = try await self.runAction(self.nodeSpec(split, [("maxBufferBytes", .number(1))]))
        }
        let invalid = await #expect(throws: FlowShellError.self) {
            _ = try await self.runAction(self.spec([
                ("command", .text("acpx-invalid-limit-must-not-spawn")), ("maxBufferBytes", .number(-1))
            ]))
        }
        #expect(invalid?.message == "Shell action maxBufferBytes must be a non-negative safe integer")
    }

    /// acpx: "shell capture preserves cancellation when a signal handler emits excess
    /// output": what a command writes as it is stopped does not fail it on the limit.
    @Test(.enabled(if: node != nil), .timeLimit(.minutes(1)))
    func outputWrittenWhileStoppingIsNoOverflow() async throws {
        let fifo = try FIFOReader.make()
        let script = "process.on('SIGTERM',()=>{process.stdout.write('x'.repeat(65536),()=>process.exit(0))});"
            + "require('node:fs').writeFileSync(\(fifo.jsPath),'ready');setInterval(()=>{},1000)"
        let owners = OwnerBox()
        let pending = Task {
            try await self.runAction(self.nodeSpec(script, [("maxBufferBytes", .number(1))]), control: FlowShellControl(
                registerOwner: { owner in
                    owners.set(owner)
                    return {}
                }))
        }
        _ = await fifo.next()
        let owner = try #require(owners.owner)
        try await owner.cancel("SIGTERM")
        await #expect(throws: FlowTimeoutError.self) { _ = try await pending.value }
    }

    /// `ctx.runShell`'s command reports a failing exit, and resolves once its pipes close.
    @Test(.enabled(if: node != nil))
    func runShellReportsAFailingExit() async throws {
        let result = try await FlowShellProcess.runCommand(
            nodeSpec(#"process.stdout.write("out"); process.exit(4)"#), cwd: NSTemporaryDirectory(),
            control: FlowShellControl())
        #expect(result.exitCode == 4)
        #expect(result.stdout == "out")
        #expect(!result.timedOut)
        #expect(result.wire(timedOut: true)["timedOut"] == .bool(false))
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        // A zombie has exited: only its new parent can reap it.
        guard kill(pid, 0) == 0, let table = ProcessTable.snapshot() else { return false }
        return table[pid] != nil
    }
}

/// Holds the owner a command registers.
private final class OwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FlowShellOwner?
    func set(_ owner: FlowShellOwner) { lock.withLock { stored = owner } }
    var owner: FlowShellOwner? { lock.withLock { stored } }
}

/// A FIFO a child writes to — its pid, or that it is ready — read as soon as it does.
final class FIFOReader: @unchecked Sendable {
    let directory: URL
    let path: URL
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var received: String?
    private var waiter: CheckedContinuation<String, Never>?

    /// The path as a JavaScript string literal.
    var jsPath: String { WireJSON.text(path.path).stringified }

    static func make(name: String = "fifo") throws -> FIFOReader {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FIFOReader(directory: directory, path: directory.appendingPathComponent(name))
    }

    private init(directory: URL, path: URL) throws {
        self.directory = directory
        self.path = path
        guard mkfifo(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let fd = open(path.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            let waiting: CheckedContinuation<String, Never>? = lock.withLock {
                guard received == nil else { return nil }
                received = text
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(returning: text)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    /// What was written first.
    func next() async -> String {
        await withCheckedContinuation { continuation in
            let text: String? = lock.withLock {
                if let received { return received }
                waiter = continuation
                return nil
            }
            if let text { continuation.resume(returning: text) }
        }
    }
}
