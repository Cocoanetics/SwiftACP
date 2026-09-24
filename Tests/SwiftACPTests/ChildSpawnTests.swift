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

    /// The command runs in its directory, however it gets there: also as on a glibc before
    /// 2.29, which has no `addchdir` spawn action, where the child changes into it itself.
    /// A directory it cannot change into fails the spawn either way (#113 review).
    @Test func theCommandRunsInItsDirectory() async throws {
        let directory = try Self.workspace()
        for withoutChangeDirectory in [false, true] {
            let process = try ChildProcess.spawn(
                command: "pwd", arguments: [], cwd: directory, environment: nil,
                withoutChangeDirectory: withoutChangeDirectory)
            let output = TerminalOutput(limit: 4096)
            let printed: String = await withCheckedContinuation { continuation in
                process.start(onOutput: { output.append($0) }, onExit: { _ in
                    continuation.resume(returning: output.read().text)
                })
            }
            process.stopReading()
            #expect(printed == directory + "\n", "withoutChangeDirectory: \(withoutChangeDirectory)")
            #expect(throws: ChildProcess.SpawnError(code: ENOENT)) {
                _ = try ChildProcess.spawn(
                    command: "pwd", arguments: [], cwd: directory + "/missing", environment: nil,
                    withoutChangeDirectory: withoutChangeDirectory)
            }
        }
    }
}
#endif
