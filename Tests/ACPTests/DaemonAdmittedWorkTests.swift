@testable import ACPXCore
@testable import acpxd
import Foundation
@testable import SwiftACP
import Testing

/// A prompt or control a client sent runs to its end whatever becomes of the client, as
/// acpx's queue owner runs a task or control it has admitted though its client goes away
/// (#181). SwiftMCP calls off a request's handler once its client's connection is gone;
/// here the request is called off as it would be then.
extension DaemonToolsTests {
    /// Wait for `stream`'s first event — bounded, so that one that never comes fails the
    /// test rather than hangs it.
    private func firstEvent(of stream: AsyncStream<Void>) async throws {
        try await withTimeout(milliseconds: 10_000) {
            var waiting = stream.makeAsyncIterator()
            _ = await waiting.next()
        }
    }

    /// A control whose request is called off while it waits for the session still runs.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlCalledOffWhileItWaitsStillRuns() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = ACPXDaemon(backend: backend)
            // Something holds the session, which the control waits for.
            try await backend.turnQueue.acquire(session.id, wait: true)
            let (queued, queuing) = AsyncStream<Void>.makeStream()
            await backend.turnQueue.setOnQueued { _ in queuing.yield() }
            let call = Task { try await daemon.setMode(sessionId: session.id, modeId: "plan") }
            try await firstEvent(of: queued)
            await backend.turnQueue.setOnQueued(nil)

            call.cancel()
            await backend.turnQueue.release(session.id)
            _ = try await withTimeout(milliseconds: 10_000) { try await call.value }
            #expect(try #require(SessionStore.loadRecord(session.id)).acpx?.desiredModeId == "plan")
            await backend.releaseAll()
        }
    }

    /// So does a prompt: it goes out, and the agent answers it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptCalledOffWhileItWaitsStillRuns() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = ACPXDaemon(backend: backend)
            try await backend.turnQueue.acquire(session.id, wait: true)
            let (queued, queuing) = AsyncStream<Void>.makeStream()
            await backend.turnQueue.setOnQueued { _ in queuing.yield() }
            let call = Task { try await daemon.runPrompt(sessionId: session.id, text: "hi") }
            try await firstEvent(of: queued)
            await backend.turnQueue.setOnQueued(nil)

            call.cancel()
            await backend.turnQueue.release(session.id)
            let reply = try await withTimeout(milliseconds: 10_000) { try await call.value }
            #expect(reply == "hello")
            #expect(session.prompts == 1)
            await backend.releaseAll()
        }
    }
}
