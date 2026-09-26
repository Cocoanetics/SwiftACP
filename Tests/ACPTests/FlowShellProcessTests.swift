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
        let rendered = FlowShell.renderCommand(try #require(Self.node), ["-e", script])
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

    /// acpx: "runShellAction rejects commands terminated by signal".
    @Test func aCommandEndedBySignalFails() async throws {
        let error = await #expect(throws: FlowShellError.self) {
            _ = try await self.runAction(self.spec([
                ("command", .text("/bin/sh")), ("args", .array([.text("-c"), .text(#"kill -TERM "$$""#)]))
            ]))
        }
        #expect(error?.message.hasSuffix(": signal SIGTERM") == true, "\(error?.message ?? "")")
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
