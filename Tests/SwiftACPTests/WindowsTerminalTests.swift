#if os(Windows)
@testable import SwiftACP
import Foundation
import Testing
import WinSDK

/// Terminals on Windows (#272), started, read and ended as acpx does there. A command with `args`
/// runs as it is, a `.cmd` through Node's own shell, and a command line that is not found as a
/// program through `cmd.exe`, which is not detached, so what its own programs print is kept
/// (openclaw/acpx#797). A direct launch ends with Node's `kill`, which Windows carries out at once
/// and Node reports as the signal; a shell launch ends with `taskkill` over its tree. Where a test
/// needs a program to be running, the program says so through a named pipe the test reads: a
/// signal, not a sleep.
@Suite(.timeLimit(.minutes(1)))
struct WindowsTerminalTests {
    /// A named pipe a program's output is sent to, and the test reads.
    final class SignalPipe: @unchecked Sendable {
        struct Unavailable: Error {}

        let path: String
        private let handle: HANDLE

        init() throws {
            let path = #"\\.\pipe\swiftacp-terminal-"# + UUID().uuidString
            let created = path.withCString(encodedAs: UTF16.self) {
                CreateNamedPipeW(
                    $0, DWORD(PIPE_ACCESS_INBOUND), DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_WAIT), 1, 0, 4096, 0, nil)
            }
            guard let created, created != INVALID_HANDLE_VALUE else { throw Unavailable() }
            self.path = path
            handle = created
        }

        deinit { CloseHandle(handle) }

        /// The first bytes a program sends: it is running.
        func firstOutput() async -> String { await read(toTheEnd: false) }

        /// The rest, up to the last program that has the pipe open closing it, as ending does.
        func rest() async -> String { await read(toTheEnd: true) }

        /// Reads block, so each runs on a thread of its own.
        private func read(toTheEnd: Bool) async -> String {
            await withCheckedContinuation { continuation in
                Thread {
                    // A writer that opened the pipe first is connected already (`ERROR_PIPE_CONNECTED`).
                    _ = ConnectNamedPipe(self.handle, nil)
                    var text = [UInt8]()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        var count: DWORD = 0
                        let read = buffer.withUnsafeMutableBytes {
                            ReadFile(self.handle, $0.baseAddress, DWORD($0.count), &count, nil)
                        }
                        // It fails once every writer has closed it (`ERROR_BROKEN_PIPE`).
                        guard read else { break }
                        text += buffer[..<Int(count)]
                        if !toTheEnd, count > 0 { break }
                    }
                    continuation.resume(returning: String(decoding: text, as: UTF8.self))
                }.start()
            }
        }
    }

    private static func create(
        _ manager: TerminalManager, _ command: String, _ args: [String]? = nil, env: [EnvVariable]? = nil
    ) async throws -> String {
        try await manager.createTerminal(
            CreateTerminalRequest(sessionId: "s", command: command, args: args, env: env)).terminalId
    }

    private static func exit(_ manager: TerminalManager, _ id: String) async throws -> WaitForTerminalExitResponse {
        try await manager.waitForTerminalExit(WaitForTerminalExitRequest(sessionId: "s", terminalId: id))
    }

    private static func output(_ manager: TerminalManager, _ id: String) async throws -> TerminalOutputResponse {
        try await manager.terminalOutput(TerminalOutputRequest(sessionId: "s", terminalId: id))
    }

    /// A command's lines, each without the spaces around it, in order of their text: its two
    /// streams share one output, in no order between them.
    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.sorted()
    }

    /// acpx's own Windows check (openclaw/acpx#797), for a command with `args`: both streams and the
    /// exit code are kept, and a released terminal is gone.
    @Test func aCommandWithArgsKeepsBothStreamsAndItsExitCode() async throws {
        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let id = try await Self.create(
            manager, "cmd.exe", ["/d", "/c", "echo out-marker& echo err-marker 1>&2& exit 23"])
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(exitCode: 23))
        let output = try await Self.output(manager, id)
        #expect(Self.lines(output.output) == ["err-marker", "out-marker"])
        #expect(!output.truncated)
        #expect(output.exitStatus == TerminalExitStatus(exitCode: 23))
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
        await #expect(throws: TerminalError.unknownTerminal(id)) { _ = try await Self.output(manager, id) }
        await manager.shutdown()
    }

    /// acpx's own Windows check for a command line (openclaw/acpx#797): run through `cmd.exe`, what
    /// the programs it starts print is kept. A detached shell gives each such program a console of
    /// its own, and its output goes there.
    @Test func aCommandLineKeepsWhatItsProgramsPrint() async throws {
        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let id = try await Self.create(manager, "cmd /d /c echo child-out& cmd /d /c echo child-err 1>&2& exit 23")
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(exitCode: 23))
        let output = try await Self.output(manager, id).output
        #expect(Self.lines(output) == ["child-err", "child-out"])
        await manager.shutdown()
    }

    /// A `.cmd` found on the request's `Path` runs through Node's own shell, as acpx gives it
    /// `shell: true`: `cmd.exe /d /s /c` and the words, joined by spaces. Started directly, as libuv
    /// finds only a `.com` or `.exe`, it would not be found.
    @Test func aCmdRunsThroughNodesShell() async throws {
        var temporary = NSTemporaryDirectory()
        while temporary.hasSuffix("\\") || temporary.hasSuffix("/") { temporary.removeLast() }
        let directory = temporary + "\\swiftacp-terminal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let script = "@echo off\r\necho cmd-args %*\r\nexit /b 7\r\n"
        _ = FileManager.default.createFile(atPath: directory + "\\run-me.cmd", contents: Data(script.utf8))
        let environment = ProcessInfo.processInfo.environment
        let pathName = environment.keys.first { $0.uppercased() == "PATH" } ?? "Path"
        let path = EnvVariable(name: pathName, value: directory + ";" + (environment[pathName] ?? ""))

        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let id = try await Self.create(manager, "run-me", ["a", "b"], env: [path])
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(exitCode: 7))
        let output = try await Self.output(manager, id).output
        #expect(Self.lines(output) == ["cmd-args a b"])
        await manager.shutdown()
    }

    /// Killing a command with `args` ends it with Node's `kill`, reported as `SIGTERM`, and ends the
    /// program it started: the pipe that program has open closes.
    @Test func killingACommandWithArgsEndsWhatItStarted() async throws {
        let pipe = try SignalPipe()
        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let id = try await Self.create(manager, "cmd.exe", ["/d", "/c", "ping -n 60 127.0.0.1 > \(pipe.path)"])
        _ = await pipe.firstOutput()
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(signal: "SIGTERM"))
        _ = await pipe.rest()
        await manager.shutdown()
    }

    /// Killing a command line ends its shell's tree with `taskkill`, as acpx does: first without
    /// `/f`, which a console program outlasts, then with it, which leaves the shell exit code 1 and
    /// nothing of the line after the program it was running.
    @Test func killingACommandLineEndsItsTree() async throws {
        let pipe = try SignalPipe()
        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let id = try await Self.create(manager, "ping -n 60 127.0.0.1 > \(pipe.path) & echo after")
        _ = await pipe.firstOutput()
        _ = try await manager.killTerminal(KillTerminalRequest(sessionId: "s", terminalId: id))
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(exitCode: 1))
        _ = await pipe.rest()
        let output = try await Self.output(manager, id).output
        #expect(!output.contains("after"), "\(output)")
        await manager.shutdown()
    }

    /// acpx's own Windows check (`terminal-windows-descendants`): a command that exits and leaves a
    /// program running, which releasing the terminal ends — it is in the command's job — and nothing
    /// else.
    @Test func releasingEndsWhatAnExitedCommandLeftRunning() async throws {
        let sibling = try ChildProcess.spawn(
            command: "ping", arguments: ["-n", "60", "127.0.0.1"], cwd: NSTemporaryDirectory(), environment: nil)
        sibling.start(onChunk: { _, _ in }, onExitStatus: { _ in })
        defer { sibling.send(ProcessSignal.kill) }
        let pipe = try SignalPipe()
        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let id = try await Self.create(manager, "cmd.exe", ["/d", "/c", "start /b ping -n 60 127.0.0.1 > \(pipe.path)"])
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(exitCode: 0))
        _ = await pipe.firstOutput()
        _ = try await manager.releaseTerminal(ReleaseTerminalRequest(sessionId: "s", terminalId: id))
        _ = await pipe.rest()
        #expect(!sibling.isExiting)
        await manager.shutdown()
    }

    /// A command that is not found, and does not read as a command line, fails as Node's `spawn`
    /// says. A `.cmd` that is not there runs through the shell all the same, which names it as a
    /// command it does not know and exits 1.
    @Test func aCommandThatIsNotThereFailsAsNodeSays() async throws {
        let manager = TerminalManager(cwd: NSTemporaryDirectory())
        let name = "swiftacp-missing-\(UUID().uuidString)"
        await #expect(throws: TerminalError.spawnFailed(command: name, code: "ENOENT")) {
            _ = try await Self.create(manager, name)
        }
        let id = try await Self.create(manager, name + ".cmd", ["x"])
        let exit = try await Self.exit(manager, id)
        #expect(exit == WaitForTerminalExitResponse(exitCode: 1))
        let output = try await Self.output(manager, id).output
        #expect(output.contains(name + ".cmd"), "\(output)")
        await manager.shutdown()
    }
}
#endif
