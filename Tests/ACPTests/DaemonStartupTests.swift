@testable import acpx
@testable import ACPXCore
import Foundation
import Testing

/// An acpxd that dies while it starts is reported at once, and why, as acpx reports its
/// queue owner (#111): how it ended, and the end of what it wrote on stderr — not, some
/// nine seconds later, that it could not be reached.
struct DaemonStartupTests {
    /// A stand-in for acpxd: a shell script doing `body`.
    private static func daemon(_ body: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("acpxd-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// How connecting fails with `daemon` as acpxd, and how long it took.
    private static func failure(starting daemon: URL) async throws -> (message: String?, took: Duration) {
        try await withIsolatedStore {
            let start = ContinuousClock.now
            let error = await #expect(throws: DaemonUnavailable.self) {
                _ = try await DaemonClient.connect(spawnIfNeeded: true, daemonExecutable: daemon.path)
            }
            return (error?.cliMessage, ContinuousClock.now - start)
        }
    }

    @Test func aDaemonThatExitsWhileStartingIsReportedAtOnce() async throws {
        let daemon = try Self.daemon("echo 'acpxd: cannot bind' >&2\nexit 3")
        defer { try? FileManager.default.removeItem(at: daemon) }
        let (message, took) = try await Self.failure(starting: daemon)
        #expect(message == """
            acpxd failed to start: exited with code 3 before binding its socket: stderr:
            acpxd: cannot bind
            """)
        #expect(took < .seconds(5))
    }

    /// One ended by a signal has no exit code: `null`, then the signal's name.
    @Test func aDaemonKilledWhileStartingIsReportedWithItsSignal() async throws {
        let daemon = try Self.daemon("echo boom >&2\nkill -9 $$")
        defer { try? FileManager.default.removeItem(at: daemon) }
        let (message, took) = try await Self.failure(starting: daemon)
        #expect(message == """
            acpxd failed to start: exited with code null, signal SIGKILL before binding its socket: stderr:
            boom
            """)
        #expect(took < .seconds(5))
    }
}
