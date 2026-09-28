@testable import acpx
@testable import ACPXCore
import Foundation
import Testing

/// An acpxd that dies while it starts is reported at once, and why, as acpx reports its
/// queue owner (#111): how it ended, and the end of what it wrote on stderr — not, some
/// nine seconds later, that it could not be reached.
@Suite(.serialized, .agentLane) struct DaemonStartupTests {
    /// A stand-in for acpxd: a shell script doing `body`.
    private static func daemon(_ body: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("acpxd-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// How connecting fails with `daemon` as acpxd, the poll held (``DaemonStartup/pollIsHeld``):
    /// only the daemon's end can end the wait for it, so a report at all is one at once. How
    /// long it took is no measure of that: on a busy machine the report waits its turn on the
    /// cooperative pool, as anything does — seven seconds, once, on CI.
    ///
    /// A minute bounds the wait, counted once the store is the test's. A `.timeLimit` would
    /// count the wait for the store too: on a busy machine, over two minutes.
    private static func failure(starting daemon: URL) async throws -> String? {
        try await withIsolatedStore {
            try await DaemonStartup.$pollIsHeld.withValue(true) {
                let error = await #expect(throws: DaemonUnavailable.self) {
                    try await withTimeout(milliseconds: 60_000) {
                        _ = try await DaemonClient.connect(spawnIfNeeded: true, daemonExecutable: daemon.path)
                    }
                }
                return error?.cliMessage
            }
        }
    }

    @Test func aDaemonThatExitsWhileStartingIsReportedAtOnce() async throws {
        let daemon = try Self.daemon("echo 'acpxd: cannot bind' >&2\nexit 3")
        defer { try? FileManager.default.removeItem(at: daemon) }
        let message = try await Self.failure(starting: daemon)
        #expect(message == """
            acpxd failed to start: exited with code 3 before binding its socket: stderr:
            acpxd: cannot bind
            """)
    }

    /// One ended by a signal has no exit code: `null`, then the signal's name.
    @Test func aDaemonKilledWhileStartingIsReportedWithItsSignal() async throws {
        let daemon = try Self.daemon("echo boom >&2\nkill -9 $$")
        defer { try? FileManager.default.removeItem(at: daemon) }
        let message = try await Self.failure(starting: daemon)
        #expect(message == """
            acpxd failed to start: exited with code null, signal SIGKILL before binding its socket: stderr:
            boom
            """)
    }

    /// One that exits cleanly while it starts — a daemon that lost the race to another — is
    /// waited past, as acpx waits past its queue owner: every wait for it runs its time, while
    /// its end is still to be seen and once it has been.
    @Test(.timeLimit(.minutes(1)))
    func aDaemonThatExitsCleanlyWhileStartingIsWaitedPast() async throws {
        let daemon = try Self.daemon("exit 0")
        defer { try? FileManager.default.removeItem(at: daemon) }
        let startup = try DaemonStartup.launch(daemon.path)
        var ended = false
        while !ended {
            ended = startup.exit != nil
            let start = ContinuousClock.now
            try await startup.pause(for: .milliseconds(100))
            #expect(ContinuousClock.now - start >= .milliseconds(100))
        }
        #expect(startup.exit?.code == 0)
        #expect(!startup.failed)
    }
}
