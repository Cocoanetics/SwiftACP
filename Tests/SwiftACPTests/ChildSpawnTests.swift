@testable import SwiftACP
import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#endif

#if os(macOS) || os(Linux)
/// Starting a child process (``ChildProcess``, ``ChildSpawn``).
@Suite(.timeLimit(.minutes(1)))
struct ChildSpawnTests {
    /// A fresh directory, as its physical path.
    static func workspace() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let physical = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(physical) }
        return String(cString: physical)
    }

    /// How a child can get into its directory: the spawn's own action, and — on Linux,
    /// where glibc before 2.29 has none — a fork that changes into it itself
    /// (`withoutChangeDirectory`).
    #if os(Linux)
    static let ways = [false, true]
    #else
    static let ways = [false]
    #endif

    /// What `process` prints before it ends.
    static func output(of process: ChildProcess) async -> String {
        let output = TerminalOutput(limit: 4096)
        let printed: String = await withCheckedContinuation { continuation in
            process.start(onOutput: { output.append($0) }, onExit: { _ in
                continuation.resume(returning: output.read().text)
            })
        }
        process.stopReading()
        return printed
    }

    /// The command runs in its directory, with its `argv[0]` as given, however it gets
    /// there. A directory it cannot change into fails the spawn either way (#113 review).
    @Test func theCommandRunsInItsDirectory() async throws {
        let directory = try Self.workspace()
        for withoutChangeDirectory in Self.ways {
            let process = try ChildProcess.spawn(
                command: "sh", arguments: ["-c", #"pwd; echo "$0""#], cwd: directory, environment: nil,
                withoutChangeDirectory: withoutChangeDirectory)
            let printed = await Self.output(of: process)
            #expect(printed == directory + "\nsh\n", "withoutChangeDirectory: \(withoutChangeDirectory)")
            #expect(throws: ChildProcess.SpawnError(code: ENOENT)) {
                _ = try ChildProcess.spawn(
                    command: "pwd", arguments: [], cwd: directory + "/missing", environment: nil,
                    withoutChangeDirectory: withoutChangeDirectory)
            }
        }
    }

    /// What cannot run fails the spawn with the error `execve` gives, however the child
    /// gets into its directory — a file that is no program `ENOEXEC`, not run as a shell
    /// script (#113 review). A script runs either way when its interpreter can.
    @Test func whatCannotRunFailsTheSpawnEitherWay() async throws {
        let directory = try Self.workspace()
        let files = FileManager.default
        try files.createDirectory(atPath: directory + "/folder", withIntermediateDirectories: false)
        for (name, text, mode) in [
            ("plain", "echo plain\n", 0o644), ("orphan", "#!/nonexistent/interpreter\n", 0o755),
            ("text", "echo text\n", 0o755), ("runs", "#!/bin/sh\necho ran\n", 0o755)
        ] {
            files.createFile(
                atPath: "\(directory)/\(name)", contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        }
        for withoutChangeDirectory in Self.ways {
            for (command, code) in [
                ("./missing", ENOENT), ("./plain", EACCES), ("./folder", EACCES), ("./orphan", ENOENT),
                ("./text", ENOEXEC), ("./plain/below", ENOTDIR)
            ] {
                #expect(
                    throws: ChildProcess.SpawnError(code: code),
                    "\(command), withoutChangeDirectory: \(withoutChangeDirectory)"
                ) {
                    _ = try ChildProcess.spawn(
                        command: command, arguments: [], cwd: directory, environment: nil,
                        withoutChangeDirectory: withoutChangeDirectory)
                }
            }
            let process = try ChildProcess.spawn(
                command: "./runs", arguments: [], cwd: directory, environment: nil,
                withoutChangeDirectory: withoutChangeDirectory)
            #expect(await Self.output(of: process) == "ran\n", "withoutChangeDirectory: \(withoutChangeDirectory)")
        }
    }

    #if os(Linux)
    /// The child starts with every standard signal at its default disposition and none
    /// blocked, whatever this process ignores or blocks, however it gets into its
    /// directory. (glibc's own signals above 31 are its to set: `posix_spawn` leaves
    /// them ignored.)
    @Test func theChildStartsWithNoSignalIgnoredOrBlocked() async throws {
        let ignored = signal(SIGUSR2, SIG_IGN)
        defer { signal(SIGUSR2, ignored) }
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGUSR1)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        for withoutChangeDirectory in Self.ways {
            let process = try ChildProcess.spawn(
                command: "grep", arguments: ["-E", "^Sig(Ign|Blk)", "/proc/self/status"], cwd: try Self.workspace(),
                environment: nil, withoutChangeDirectory: withoutChangeDirectory)
            // `SigBlk`, then `SigIgn`: a bit a signal, signal 1 the lowest.
            let masks = await Self.output(of: process).split(separator: "\n").compactMap {
                $0.split(separator: "\t").last.flatMap { UInt64($0, radix: 16) }
            }
            #expect(masks.count == 2 && masks[0] == 0, "\(masks), \(withoutChangeDirectory)")
            #expect(masks.count == 2 && masks[1] & 0x7FFF_FFFF == 0, "\(masks), \(withoutChangeDirectory)")
        }
    }
    #endif

    /// A NUL anywhere in what a child is started with fails the spawn, as Node refuses
    /// it, instead of running what comes before it; an agent's launch fails as acpx's
    /// `AgentSpawnError` has it (#113 review).
    @Test func aNULFailsTheSpawn() async throws {
        let directory = try Self.workspace()
        let nul = "a\u{0}b"
        for (command, arguments, environment) in [
            ("echo" + nul, [String](), [String: String]?.none), ("echo", [nul], nil), ("echo", [], ["X": nul]),
            ("echo", [], [nul: "x"])
        ] {
            #expect(throws: ChildProcess.SpawnError(code: EINVAL)) {
                _ = try ChildProcess.spawn(
                    command: command, arguments: arguments, cwd: directory, environment: environment)
            }
        }
        let error = await #expect(throws: AgentLaunchError.self) {
            _ = try await ACPAgent.launch(
                agent: "echo", argv: ["echo", nul], cwd: directory, permission: .approveAll, inheritStderr: false)
        }
        #expect(error?.localizedDescription == "Failed to spawn agent command: echo")
    }
}
#endif
