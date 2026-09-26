@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A prompt is the session's from the moment it begins, before it holds the session's slot,
/// and a session shutting down takes none: acpx's queue owner refuses its pending tasks as it
/// shuts down (`beginShutdown`), and any sent meanwhile (`enqueue`). Split from
/// `DaemonPromptBeginTests.swift` to keep that file inside the 500-line limit.
extension DaemonToolsTests {
    /// A close — or a release, for `sessions new` — refuses the prompts waiting in line behind
    /// the one running, none of them sent, as acpx's owner refuses its pending tasks as it shuts
    /// down (`beginShutdown`); the client hears it as acpx's CLI does (Codex review on #196).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["close", "release"])
    func shuttingASessionDownRefusesThePromptsInLine(how: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' ")
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let running = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let client = CallingClient()
            let inLine = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: client)
            }
            try await nextEvent(waits)

            if how == "close" {
                #expect(try await daemon.closeSession(sessionId: session.id))
            } else {
                #expect(try await daemon.releaseSession(sessionId: session.id))
            }
            await #expect(throws: QueueOwnerShuttingDown(inLine: true)) {
                _ = try await withTimeout(milliseconds: 10_000) { try await inLine.value }
            }
            let failure = try #require(client.failure)
            #expect(failure.message == "Queue owner shutting down before prompt execution")
            #expect(failure.detailCode == "QUEUE_OWNER_SHUTTING_DOWN")
            #expect(failure.origin == "queue" && failure.retryable == true)
            _ = try? await withTimeout(milliseconds: 10_000) { try await running.value }
            #expect(session.prompts == 1, "the prompt in line never went out")
            await daemon.releaseAll()
        }
    }

    /// So is a prompt sent while the session is being closed or let go, until that is over, as
    /// acpx's owner refuses a task once it shuts down (`enqueue`) (Codex review on #196).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["close", "release"])
    func aPromptSentWhileASessionShutsDownIsRefused(how: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            // Something holds the session, which the close waits for.
            try await daemon.turnQueue.acquire(session.id, wait: true)
            let (queued, queuing) = AsyncStream<Void>.makeStream()
            await daemon.turnQueue.setOnQueued { _ in queuing.yield() }
            let shutdown = Task {
                how == "close"
                    ? try await daemon.closeSession(sessionId: session.id)
                    : try await daemon.releaseSession(sessionId: session.id)
            }
            try await nextEvent(queued)
            await daemon.turnQueue.setOnQueued(nil)

            let client = CallingClient()
            await #expect(throws: QueueOwnerShuttingDown(inLine: false)) {
                _ = try await withTimeout(milliseconds: 10_000) {
                    try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: client)
                }
            }
            #expect(client.failure?.message == "Queue owner is shutting down")
            await daemon.turnQueue.release(session.id)
            _ = try await withTimeout(milliseconds: 10_000) { try await shutdown.value }
            #expect(session.prompts == 0)
        }
    }

    /// A prompt is the session's before it takes the slot, whether it waits for it or not: a
    /// cancel sent on its way there is its, and it ends unsent (Codex review on #196).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [true, false])
    func aPromptIsTheSessionsBeforeItTakesTheSlot(wait: Bool) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let cancelled = Answer()
            await daemon.turnQueue.setBeforeAcquire { recordId in
                guard !cancelled.given else { return }
                cancelled.give((try? await daemon.cancelSession(sessionId: recordId)) == true)
            }
            let reply = try await withTimeout(milliseconds: 10_000) {
                try await daemon.runPrompt(sessionId: session.id, text: "hi", wait: wait)
            }
            await daemon.turnQueue.setBeforeAcquire(nil)
            #expect(cancelled.value == true, "the cancel found the prompt")
            #expect(reply == "")
            #expect(session.prompts == 0)
            await daemon.releaseAll()
        }
    }

    /// What a hook answered, once.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Bool?
        var given: Bool { lock.withLock { answer != nil } }
        var value: Bool? { lock.withLock { answer } }
        func give(_ value: Bool) { lock.withLock { answer = answer ?? value } }
    }

    /// A daemon that is stopping takes no prompt, as acpx's owner takes no task once it shuts
    /// down (`enqueue`): nothing is sent, and nothing kept.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aStoppingDaemonTakesNoPrompt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await daemon.releaseAll()
            let client = CallingClient()
            await #expect(throws: QueueOwnerShuttingDown(inLine: false)) {
                _ = try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: client)
            }
            #expect(client.failure?.message == "Queue owner is shutting down")
            #expect(session.prompts == 0)
            #expect(try #require(SessionStore.loadRecord(session.id)).messages.isEmpty)
        }
    }
}
