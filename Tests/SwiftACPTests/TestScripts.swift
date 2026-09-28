#if os(macOS) || os(Linux)
import Foundation
@testable import SwiftACP

/// Programs a test writes and then runs. Written by this process, a program's file can be held
/// open by a child another test spawns meanwhile, which takes this process's descriptors with it
/// until its own `exec`. Running the program in that moment fails with `ETXTBSY` on Linux, as
/// `GrokBuildAuthTests` did on CI. So this process writes only the program's text, to a file of
/// its own, and `install` writes the program: another process, whose descriptor none of this
/// process's children can hold.
enum TestScripts {
    struct InstallFailed: Error, CustomStringConvertible {
        let status: TerminalExitStatus
        var description: String { "install ended with \(status)" }
    }

    /// Write `text` to an executable file at `path`, with `mode`.
    static func write(_ text: String, to path: String, mode: Int = 0o755) async throws {
        let source = path + ".text-\(UUID().uuidString)"
        try Data(text.utf8).write(to: URL(fileURLWithPath: source))
        defer { try? FileManager.default.removeItem(atPath: source) }
        let installer = try ChildProcess.spawn(
            command: "/usr/bin/install", arguments: ["-m", String(mode, radix: 8), source, path],
            cwd: NSTemporaryDirectory(), environment: nil)
        let status = await withCheckedContinuation { continuation in
            installer.start(onOutput: { _ in }, onExit: { continuation.resume(returning: ChildProcess.exitStatus($0)) })
        }
        guard status.exitCode == 0 else { throw InstallFailed(status: status) }
    }
}
#endif
