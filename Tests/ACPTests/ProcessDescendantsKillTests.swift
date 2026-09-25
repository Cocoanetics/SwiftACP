@testable import ACPXCore
@testable import SwiftACP
import Foundation
import Testing

/// A process `ProcessDescendants` tracks stays tracked when a signal to it is refused, as
/// acpx 0.19.3's does (#783): a refused signal is no receipt of an exit, and only a fresh
/// snapshot lets the process go.
extension DaemonToolsTests {
    @Test(.timeLimit(.minutes(1)))
    func aRefusedSignalLeavesTheProcessTrackedUntilASnapshot() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let reaped = directory.appendingPathComponent("reaped")
        guard mkfifo(started.path, 0o600) == 0, mkfifo(reaped.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let pidFile = directory.appendingPathComponent("pid")
        // A shell whose background `sleep` is its descendant; it says when the sleep has
        // started, and again once it has reaped it.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 60 & echo $! > '\(pidFile.path)'; echo x > '\(started.path)'; wait; "
            + "echo x > '\(reaped.path)'"]
        try shell.run()
        defer { if shell.isRunning { shell.terminate() }; shell.waitUntilExit() }
        try await withTimeout(milliseconds: 10_000) { try await Self.byteWritten(to: started) }
        let written = try String(contentsOf: pidFile, encoding: .utf8)
        let sleep = try #require(pid_t(written.trimmingCharacters(in: .whitespacesAndNewlines)))

        let descendants = ProcessDescendants(root: shell.processIdentifier, ownProcessGroup: false)
        #expect(descendants.capture(rootIsRunning: true))
        #expect(descendants.hasTrackedProcesses)
        kill(sleep, SIGKILL)
        try await withTimeout(milliseconds: 10_000) { try await Self.byteWritten(to: reaped) }

        // The sleep is gone: signal 0 to it is refused, and it stays tracked...
        descendants.signalTracked(0)
        #expect(descendants.hasTrackedProcesses)
        // ...until a snapshot finds it gone.
        #expect(descendants.capture(rootIsRunning: false))
        #expect(!descendants.hasTrackedProcesses)
    }
}
