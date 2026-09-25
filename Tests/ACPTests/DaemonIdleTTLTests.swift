@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// How long acpxd holds a session once its turns are over: acpx's `--ttl` (#106). acpx's
/// queue owner waits that long for its next prompt, then stops — its agent closed, and
/// how the agent ended written to the record — and a running owner keeps the TTL it was
/// started with.
extension DaemonToolsTests {
    /// With no prompt for its TTL, the session is let go as acpx's owner stops: its agent
    /// closed, the record without a pid and with how the agent ended.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionIsLetGoOnceIdleForItsTTL() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (stopped, stop) = AsyncStream<String>.makeStream()
            await daemon.setOwnerStopped { stop.yield($0) }
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 200), client: CallingClient())
            #expect(await stopped.first { _ in true } == session.id)
            #expect(await daemon.sessionStatus(sessionId: session.id).live == false)
            let record = try #require(SessionStore.loadRecord(session.id))
            #expect(record.pid == nil)
            #expect(record.lastAgentDisconnectReason == "connection_close")
            await daemon.releaseAll()
        }
    }

    /// A TTL of `0` keeps the session: its owner waits for no time at all.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTTLOfZeroKeepsTheSession() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            let owner = try #require(await daemon.owners[session.id])
            #expect(owner.ttlMilliseconds == nil)
            #expect(await daemon.sessionStatus(sessionId: session.id).live)
            await daemon.releaseAll()
        }
    }

    /// A session held already keeps the TTL its owner was started with, whatever a later
    /// prompt asks — as a prompt given to acpx's running owner does not change it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionKeepsItsTTL() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 100), client: CallingClient())
            #expect(try #require(await daemon.owners[session.id]).ttlMilliseconds == nil)
            await daemon.releaseAll()
        }
    }

    /// acpx's `normalizeQueueOwnerTtlMs`: five minutes unless given, and none for `0`.
    @Test func aTTLIsTakenAsAcpxTakesIt() {
        #expect(ACPXDaemonBackend.ownerTTL(nil) == DEFAULT_TTL_MS)
        #expect(ACPXDaemonBackend.ownerTTL(-1) == DEFAULT_TTL_MS)
        #expect(ACPXDaemonBackend.ownerTTL(0) == nil)
        #expect(ACPXDaemonBackend.ownerTTL(1_500) == 1_500)
    }
}

extension ACPXDaemonBackend {
    func setOwnerStopped(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        ownerStopped = hook
    }
}
