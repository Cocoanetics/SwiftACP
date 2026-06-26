@testable import acpx
@testable import ACPXCore
@testable import acpxd
import Foundation
import Logging
import ServiceLifecycle
import SwiftACP
import SwiftMCP
import Testing

/// The single-manager guarantees: the `acpxd` boot lock keeps exactly one daemon
/// alive, and the daemon serializes turns per session so concurrent CLI/MCP callers
/// can't collide on one session or clobber its persisted history.
///
/// Serialized because the store/lock tests redirect the process-wide
/// ``ACPXPaths/baseDir``.
@Suite(.serialized) struct SingleManagerTests {
    // MARK: - DaemonLock (singleton boot lock)

    @Test func acquireSucceedsAndBlocksASecondLiveHolder() async throws {
        try await withIsolatedStore {
            let lock = DaemonLock()
            let acquired = try lock.acquire()
            #expect(acquired)
            // The lock now names a live pid (this process), so a second acquire fails.
            let blocked = try DaemonLock().acquire()
            #expect(!blocked)
            lock.release()
            // Released → free to acquire again.
            let again = DaemonLock()
            let reacquired = try again.acquire()
            #expect(reacquired)
            again.release()
        }
    }

    @Test func staleLockFromDeadProcessIsReclaimed() async throws {
        try await withIsolatedStore {
            let dead = reapedChildPid()
            #expect(DaemonLock.isProcessAlive(dead) == false)
            try writeDaemonHolder(pid: dead)
            // The holder is gone, so the lock is stale and gets taken over.
            let lock = DaemonLock()
            #expect(try lock.acquire())
            #expect(lock.currentHolder()?.pid == lock.pid)
            lock.release()
        }
    }

    @Test func liveForeignLockIsNotStolen() async throws {
        try await withIsolatedStore {
            // pid 1 (launchd) is always alive but not ours — kill(1, 0) → EPERM.
            #expect(DaemonLock.isProcessAlive(1))
            try writeDaemonHolder(pid: 1)
            #expect(try DaemonLock().acquire() == false)
            // The foreign lock is left intact.
            #expect(DaemonLock().currentHolder()?.pid == 1)
        }
    }

    @Test func releaseOnlyRemovesOwnLock() async throws {
        try await withIsolatedStore {
            try writeDaemonHolder(pid: 1) // "another" daemon owns it
            DaemonLock().release() // our pid ≠ holder → no-op
            #expect(DaemonLock().currentHolder()?.pid == 1)
        }
    }

    @Test func recordsBoundPortAndReadsItBack() async throws {
        try await withIsolatedStore {
            let lock = DaemonLock()
            let acquired = try lock.acquire()
            #expect(acquired)
            #expect(lock.currentHolder()?.port == nil) // none until the listener binds
            lock.update(port: 54321)
            #expect(lock.currentHolder()?.port == 54321)
            lock.release()
        }
    }

    @Test func holderWithoutPortDecodesAsNilPort() throws {
        // An older lock (written before the port field existed) still decodes.
        let json = #"{"pid":1,"startedAt":"2026-01-01T00:00:00.000Z"}"#
        let holder = try JSONDecoder().decode(DaemonLock.Holder.self, from: Data(json.utf8))
        #expect(holder.pid == 1)
        #expect(holder.port == nil)
    }

    @Test func liveEndpointReflectsLockPort() async throws {
        try await withIsolatedStore {
            // No lock yet → the CLI has no endpoint to connect to.
            #expect(DaemonClient.liveEndpoint() == nil)
            let lock = DaemonLock()
            let acquired = try lock.acquire()
            #expect(acquired)
            // A live holder without a recorded port still yields no endpoint.
            #expect(DaemonClient.liveEndpoint() == nil)
            lock.update(port: 49152)
            guard case .direct(let host, let port)? = DaemonClient.liveEndpoint()?.endpoint else {
                Issue.record("expected a direct 127.0.0.1 endpoint")
                lock.release()
                return
            }
            #expect(host == "127.0.0.1")
            #expect(port == 49152)
            lock.release()
        }
    }

    @Test func daemonServiceReleasesLockOnGracefulShutdown() async throws {
        try await withIsolatedStore {
            let lock = DaemonLock()
            let acquired = try lock.acquire()
            #expect(acquired)
            // Run the daemon as a service, then ask the group to shut down gracefully:
            // it's torn down last and releases the lock once its run() returns.
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false, lock: lock)
            let group = ServiceGroup(configuration: .init(
                services: [.init(
                    service: daemon, successTerminationBehavior: .gracefullyShutdownGroup,
                    failureTerminationBehavior: .gracefullyShutdownGroup)],
                logger: Logger(label: "test.acpxd")))
            let running = Task { try await group.run() }
            // Let group.run() reach its running state first; triggering while it's
            // still .initial would finish the group and make run() throw.
            try await Task.sleep(nanoseconds: 200_000_000)
            await group.triggerGracefulShutdown()
            try await running.value
            #expect(lock.currentHolder() == nil)
        }
    }

    // MARK: - Per-session turn serialization

    @Test func turnSlotIsExclusivePerSessionAndHonorsNoWait() async throws {
        let queue = SessionTurnQueue()
        try await queue.acquire("s1", wait: true)
        // Busy + --no-wait → rejected immediately rather than queueing.
        await #expect(throws: DaemonError.self) {
            try await queue.acquire("s1", wait: false)
        }
        // A different session is independent.
        try await queue.acquire("s2", wait: false)
        // Releasing s1 frees it for the next caller.
        await queue.release("s1")
        try await queue.acquire("s1", wait: false)
        await queue.release("s1")
        await queue.release("s2")
    }

    @Test func queuedWaiterProceedsAfterRelease() async throws {
        let queue = SessionTurnQueue()
        try await queue.acquire("s", wait: true)
        // A waiter queues behind the held slot; it must proceed once released
        // (never deadlock), whether it enqueued before or after the release.
        let waiter = Task { try await queue.acquire("s", wait: true) }
        await queue.release("s")
        try await waiter.value
        await queue.release("s")
    }

    @Test(.enabled(if: mockPythonAvailable))
    func concurrentTurnsSerializeAndPreserveHistory() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            // Two turns fired at once must be serialized per session, and each must
            // build on the other's persisted history rather than clobbering it.
            async let first = daemon.runPrompt(sessionId: id, text: "first")
            async let second = daemon.runPrompt(sessionId: id, text: "second")
            _ = try await (first, second)

            let record = try #require(SessionStore.loadRecord(id))
            let history = SessionStore.conversationHistoryEntries(record)
            #expect(history.count == 4)
            #expect(history.map(\.role) == ["user", "assistant", "user", "assistant"])
            let prompts = Set(history.filter { $0.role == "user" }.map(\.textPreview))
            #expect(prompts == ["first", "second"])
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func concurrentPromptAndControlOpSerializeWithoutClobber() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            // A prompt and a set-mode fired at once must serialize on the session. The
            // control op reloads after acquiring its slot, so it persists on top of the
            // turn's history instead of clobbering it — either order leaves both effects.
            async let prompt = daemon.runPrompt(sessionId: id, text: "ping")
            async let mode = daemon.setMode(sessionId: id, modeId: "auto")
            _ = try await (prompt, mode)

            let record = try #require(SessionStore.loadRecord(id))
            let history = SessionStore.conversationHistoryEntries(record)
            #expect(history.contains { $0.role == "user" && $0.textPreview == "ping" })
            #expect(history.contains { $0.role == "assistant" })
            #expect(record.acpx?.currentModeId == "auto")
        }
    }
}

// MARK: - helpers

/// Write a daemon lock file owned by `pid` (for the stale / foreign-holder tests).
private func writeDaemonHolder(pid: Int32) throws {
    let url = ACPXPaths.daemonLockPath
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(DaemonLock.Holder(pid: pid, startedAt: nowISO()))
    try data.write(to: url)
}

/// A pid guaranteed to be dead: launch `/usr/bin/true` and reap it.
private func reapedChildPid() -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? process.run()
    process.waitUntilExit()
    return process.processIdentifier
}
