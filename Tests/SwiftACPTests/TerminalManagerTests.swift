#if os(macOS) || os(Linux)
@testable import SwiftACP
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// acpx's `TerminalManager` behaviour with real commands (#82). Every expected value is
/// what acpx 0.19.1 answered for the same request. Where a test needs a command to have
/// reached some point, the command says so through a FIFO the test reads: a signal,
/// not a sleep.
@Suite(.timeLimit(.minutes(1)))
struct TerminalManagerTests {
    /// A named pipe a command writes to and the test reads from.
    struct Fifo {
        let path: String

        init() throws {
            path = NSTemporaryDirectory() + "terminal-\(UUID().uuidString).fifo"
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(.EIO) }
        }

        /// What one writer sends, up to its closing the pipe. Opening blocks until the
        /// command opens its end, so this runs on a thread of its own.
        func read() async -> String {
            await withCheckedContinuation { continuation in
                Thread {
                    let text = FileHandle(forReadingAtPath: path).map {
                        String(decoding: $0.readDataToEndOfFile(), as: UTF8.self)
                    }
                    continuation.resume(returning: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                }.start()
            }
        }

        /// Send a line to a command reading the pipe; blocks until it opens its end.
        func write(_ text: String) {
            Thread {
                let handle = FileHandle(forWritingAtPath: path)
                handle?.write(Data((text + "\n").utf8))
                try? handle?.close()
            }.start()
        }

        func remove() { unlink(path) }
    }

    /// A new directory, by its physical path — what `pwd` prints. (Foundation's
    /// `resolvingSymlinksInPath` keeps macOS's `/var` rather than `/private/var`.)
    func workspace() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let physical = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(physical) }
        return String(cString: physical)
    }

    /// Create, wait, read and release, as an agent running one command does.
    func run(
        _ manager: TerminalManager, _ command: String, _ args: [String]? = nil, cwd: String? = nil,
        env: [EnvVariable]? = nil, limit: Int? = nil
    ) async throws -> (exit: WaitForTerminalExitResponse, output: TerminalOutputResponse) {
        let id = try await manager.createTerminal(CreateTerminalRequest(
            sessionId: "s", command: command, args: args, cwd: cwd, env: env, outputByteLimit: limit)).terminalId
        let exit = try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
        let output = try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
        return (exit, output)
    }

    func isAlive(_ pid: pid_t) -> Bool { ProcessTable.snapshot()?[pid] != nil }

    /// `sh -c script`, with the FIFO's path as `$1`.
    func shell(_ script: String, _ fifo: Fifo) -> CreateTerminalRequest {
        CreateTerminalRequest(sessionId: "s", command: "sh", args: ["-c", script, "sh", fifo.path])
    }

    // MARK: - Running

    @Test func aCommandsOutputAndExitAreReported() async throws {
        let (exit, output) = try await run(TerminalManager(cwd: try workspace()), "echo", ["hello", "world"])
        #expect(exit == WaitForTerminalExitResponse(exitCode: 0))
        #expect(output.output == "hello world\n")
        #expect(!output.truncated)
        #expect(output.exitStatus == TerminalExitStatus(exitCode: 0))
    }

    /// stdout and stderr land in one output; the exit code is the command's.
    @Test func stderrJoinsTheOutput() async throws {
        let (exit, output) = try await run(
            TerminalManager(cwd: try workspace()), "sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(exit == WaitForTerminalExitResponse(exitCode: 3))
        #expect(output.output == "out\nerr\n")
    }

    /// A command ended by a signal reports the signal's name and no exit code.
    @Test func aSignalIsReportedByName() async throws {
        let (exit, output) = try await run(TerminalManager(cwd: try workspace()), "sh", ["-c", "kill -TERM $$"])
        #expect(exit == WaitForTerminalExitResponse(signal: "SIGTERM"))
        #expect(output.exitStatus == TerminalExitStatus(signal: "SIGTERM"))
    }

    /// No `args`, not a program, and shell syntax: acpx runs the line through `sh -c`.
    @Test func aShellLineRunsThroughTheShell() async throws {
        let (exit, output) = try await run(TerminalManager(cwd: try workspace()), "echo hi | tr a-z A-Z")
        #expect(exit.exitCode == 0)
        #expect(output.output == "HI\n")
    }

    /// With `args`, the command is a program name, however it reads.
    @Test func givenArgumentsTheLineIsAProgramName() async throws {
        let manager = TerminalManager(cwd: try workspace())
        await #expect(throws: TerminalError.spawnFailed(command: "echo hi | tr a-z A-Z", code: "ENOENT")) {
            try await manager.createTerminal(CreateTerminalRequest(
                sessionId: "s", command: "echo hi | tr a-z A-Z", args: []))
        }
        #expect(TerminalError.spawnFailed(command: "x", code: "ENOENT").description == "spawn x ENOENT")
    }

    /// A plain name that is not a program is Node's `spawn <name> ENOENT`.
    @Test func aMissingProgramIsENOENT() async throws {
        let manager = TerminalManager(cwd: try workspace())
        await #expect(throws: TerminalError.spawnFailed(command: "definitely-not-a-command-xyz", code: "ENOENT")) {
            try await manager.createTerminal(CreateTerminalRequest(
                sessionId: "s", command: "definitely-not-a-command-xyz"))
        }
    }

    /// A path with whitespace that does not exist goes to the shell, which says so.
    @Test func aMissingPathWithWhitespaceGoesToTheShell() async throws {
        let (exit, output) = try await run(TerminalManager(cwd: try workspace()), "./nope/x y")
        #expect(exit.exitCode == 127)
        #expect(output.output.contains("./nope/x"))
    }

    // MARK: - Where and with what

    @Test func aCommandRunsInTheManagersDirectoryUnlessTheRequestNamesOne() async throws {
        let root = try workspace()
        let other = try workspace()
        let manager = TerminalManager(cwd: root)
        #expect(try await run(manager, "pwd").output.output == root + "\n")
        #expect(try await run(manager, "pwd", cwd: other).output.output == other + "\n")
    }

    /// Node reports a missing working directory as the command not being found.
    @Test func aMissingDirectoryIsENOENT() async throws {
        let manager = TerminalManager(cwd: try workspace())
        await #expect(throws: TerminalError.spawnFailed(command: "pwd", code: "ENOENT")) {
            try await manager.createTerminal(CreateTerminalRequest(
                sessionId: "s", command: "pwd", cwd: "/nonexistent-dir-\(UUID().uuidString)"))
        }
    }

    /// The request's variables join this process's environment.
    @Test func theRequestsVariablesAreAdded() async throws {
        let (_, output) = try await run(
            TerminalManager(cwd: try workspace()), "sh", ["-c", "echo \"$ACP_TERMINAL_ONE:$ACP_TERMINAL_TWO\""],
            env: [EnvVariable(name: "ACP_TERMINAL_ONE", value: "1")])
        #expect(output.output == "1:\n")
    }

    // MARK: - Output limits

    @Test func theRequestsLimitKeepsTheNewestBytes() async throws {
        let manager = TerminalManager(cwd: try workspace())
        let limited = try await run(manager, "printf", ["héllo wörld"], limit: 5).output
        #expect(limited.output == "örld")
        #expect(limited.truncated)
        let nothing = try await run(manager, "printf", ["abc"], limit: 0).output
        #expect(nothing.output == "" && nothing.truncated)
    }

    @Test func theHostCeilingCapsEveryTerminal() async throws {
        let manager = TerminalManager(cwd: try workspace(), outputCeiling: 3)
        #expect(try await run(manager, "printf", ["abcdef"]).output.output == "def")
        #expect(try await run(manager, "printf", ["abcdef"], limit: 2).output.output == "ef")
    }

    @Test func invalidUTF8IsReplaced() async throws {
        let (_, output) = try await run(TerminalManager(cwd: try workspace()), "printf", ["\\377\\376ok"])
        #expect(output.output == "\u{FFFD}\u{FFFD}ok")
    }

    // MARK: - While it runs

    /// The exit is reported only once everything the command wrote before it is in —
    /// an agent reads the output right after waiting — even when reading has fallen as
    /// far behind as it can: not started until the exit needs it.
    @Test func theExitIsReportedWithTheOutputBeforeItIn() async throws {
        let process = try TerminalProcess.spawn(
            command: "printf", arguments: ["everything"], cwd: try workspace(), environment: nil)
        let output = TerminalOutput(limit: 100)
        let seenAtExit: String = await withCheckedContinuation { continuation in
            process.start(
                onOutput: { output.append($0) },
                onExit: { _ in continuation.resume(returning: output.read().text) },
                readerStartsLate: true)
        }
        #expect(seenAtExit == "everything")
        process.stopReading()
    }

    /// A background child writing faster than its output is taken in does not hold up
    /// the exit: what the command left in the pipe when it exited is taken in, and no
    /// more. (`yes` fills the pipe before the command exits, and a reader slower than
    /// `yes` keeps it from ever running dry.)
    @Test func aBackgroundWriterDoesNotHoldUpTheExit() async throws {
        let process = try TerminalProcess.spawn(
            command: "sh", arguments: ["-c", "yes & sleep 0.2; exit 0"], cwd: try workspace(), environment: nil)
        // The sleep only bounds a hang, so the test fails rather than never ending.
        let reported = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            process.start(onOutput: { _ in usleep(10_000) }, onExit: { _ in
                if once.claim() { continuation.resume(returning: true) }
            })
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        #expect(reported)
        // `yes` still runs in the command's process group, which outlives its leader.
        killpg(process.pid, SIGKILL)
        process.stopReading()
    }

    /// Whichever claims first.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }

    /// Output read before the exit carries no exit status.
    @Test func aRunningCommandHasNoExitStatusYet() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace())
        let id = try await manager.createTerminal(shell("read line < \"$1\"; echo \"$line\"", fifo)).terminalId
        let running = try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        #expect(running.exitStatus == nil)
        fifo.write("done")
        let exit = try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
        #expect(exit.exitCode == 0)
        let finished = try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        #expect(finished.output == "done\n")
        #expect(finished.exitStatus == TerminalExitStatus(exitCode: 0))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    /// The exit is the command's own: a background child still holding the output open
    /// does not keep the wait from answering.
    @Test func theWaitEndsWithTheCommandNotItsBackgroundChildren() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace())
        let script = "(read line < \"$1\"; echo late) & echo early"
        let id = try await manager.createTerminal(shell(script, fifo)).terminalId
        let exit = try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
        #expect(exit.exitCode == 0)
        let output = try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        #expect(output.output == "early\n")
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    // MARK: - Killing

    /// A killed command gets `SIGTERM`, stays readable, and is gone once released.
    @Test func killEndsTheCommandAndKeepsTheTerminal() async throws {
        let manager = TerminalManager(cwd: try workspace())
        let id = try await manager.createTerminal(CreateTerminalRequest(
            sessionId: "s", command: "sleep", args: ["30"])).terminalId
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        let exit = try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
        #expect(exit == WaitForTerminalExitResponse(signal: "SIGTERM"))
        let output = try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        #expect(output.exitStatus == TerminalExitStatus(signal: "SIGTERM"))

        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
        await #expect(throws: TerminalError.unknownTerminal(id)) {
            try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        }
        // Released twice is still released.
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    /// Everything the command started goes with it — the rest of its process group.
    @Test func killEndsWhatTheCommandStarted() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace())
        let id = try await manager.createTerminal(shell("sleep 30 & echo $! > \"$1\"; sleep 31", fifo)).terminalId
        let child = try #require(pid_t(await fifo.read()))
        #expect(isAlive(child))
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        #expect(!isAlive(child))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    /// A child that left the group — a daemon calling `setsid` — was seen as the
    /// command's child, so it is signalled too.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func killEndsAChildThatLeftTheGroup() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace())
        let daemon = #"perl -MPOSIX -e 'POSIX::setsid(); open(F, ">", $ARGV[0]); print F "$$\n"; close F; "#
            + #"sleep 30' "$1""#
        let id = try await manager.createTerminal(shell("\(daemon) & sleep 31", fifo)).terminalId
        let escaped = try #require(pid_t(await fifo.read()))
        #expect(isAlive(escaped))
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        #expect(!isAlive(escaped))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    /// What the command left running when it exited is still its own: killing the
    /// finished terminal ends it.
    @Test func killAfterTheExitStillEndsWhatWasLeftRunning() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace())
        let id = try await manager.createTerminal(shell("sleep 30 & echo $! > \"$1\"", fifo)).terminalId
        let child = try #require(pid_t(await fifo.read()))
        let exit = try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
        #expect(exit.exitCode == 0)
        #expect(isAlive(child))
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        #expect(!isAlive(child))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    /// A command ignoring `SIGTERM` gets `SIGKILL` once the grace period is over.
    @Test func aCommandIgnoringTermIsKilled() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace(), killGrace: 0.2)
        let id = try await manager.createTerminal(shell("trap '' TERM; echo ready > \"$1\"; sleep 30", fifo)).terminalId
        #expect(await fifo.read() == "ready")
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        let exit = try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
        #expect(exit == WaitForTerminalExitResponse(signal: "SIGKILL"))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
    }

    /// Shutting down releases every terminal, killing what still runs.
    @Test func shutdownReleasesEveryTerminal() async throws {
        let fifo = try Fifo()
        defer { fifo.remove() }
        let manager = TerminalManager(cwd: try workspace())
        let id = try await manager.createTerminal(shell("echo $$ > \"$1\"; exec sleep 30", fifo)).terminalId
        let command = try #require(pid_t(await fifo.read()))
        await manager.shutdown()
        #expect(!isAlive(command))
        await #expect(throws: TerminalError.unknownTerminal(id)) {
            try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
        }
    }

    /// Once shutdown has begun, no command starts: it would outlive the connection.
    @Test func nothingStartsOnceShutdownHasBegun() async throws {
        let manager = TerminalManager(cwd: try workspace())
        await manager.shutdown()
        await #expect(throws: CancellationError.self) {
            try await manager.createTerminal(CreateTerminalRequest(sessionId: "s", command: "true"))
        }
    }

    /// Only stdin, stdout and stderr reach the command — not a descriptor this process
    /// holds without close-on-exec. On Linux also the way it is done without glibc
    /// 2.34's `closefrom` action.
    @Test func onlyTheStandardDescriptorsReachTheCommand() async throws {
        let file = open("/dev/null", O_RDONLY)
        // The lowest free descriptor from 200 on, without close-on-exec.
        let held = fcntl(file, F_DUPFD, 200)
        close(file)
        defer { close(held) }
        #if os(Linux)
        let (listing, ways) = ("/proc/self/fd", [false, true])
        #else
        let (listing, ways) = ("/dev/fd", [false])
        #endif
        for withoutCloseFrom in ways {
            let process = try TerminalProcess.spawn(
                command: "ls", arguments: [listing], cwd: try workspace(), environment: nil,
                withoutCloseFrom: withoutCloseFrom)
            let output = TerminalOutput(limit: 4096)
            let listed: String = await withCheckedContinuation { continuation in
                process.start(onOutput: { output.append($0) }, onExit: { _ in
                    continuation.resume(returning: output.read().text)
                })
            }
            process.stopReading()
            let descriptors = listed.split(separator: "\n").map(String.init)
            #expect(descriptors.contains("2"), "\(listed)")
            #expect(!descriptors.contains(String(held)), "withoutCloseFrom: \(withoutCloseFrom)")
        }
    }

    /// An id never handed out is unknown to everything but release, which has nothing
    /// to do — acpx answers `{}`.
    @Test func anUnknownTerminalIsRefusedExceptByRelease() async throws {
        let manager = TerminalManager(cwd: try workspace())
        await #expect(throws: TerminalError.unknownTerminal("nope")) {
            try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: "nope"))
        }
        await #expect(throws: TerminalError.unknownTerminal("nope")) {
            try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: "nope"))
        }
        await #expect(throws: TerminalError.unknownTerminal("nope")) {
            try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: "nope"))
        }
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: "nope"))
        #expect(TerminalError.unknownTerminal("nope").description == "Unknown terminal: nope")
    }
}
#endif
