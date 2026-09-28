@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// How a session's line takes a prompt, as acpx's queue owner takes one (`enqueue`): past the
/// owner's depth it is refused (#240).
extension DaemonToolsTests {
    /// A prompt that would wait behind as many as the depth allows is refused, in acpx's words:
    /// the depth the line began with until the session has an owner, then the owner's — never
    /// the one the prompt itself brings, as acpx's owner keeps the depth it was spawned with.
    @Test func aPromptPastTheQueueDepthIsRefused() async throws {
        // Bounded, so that a line that never moves fails rather than hangs.
        try await withTimeout(milliseconds: 10_000) {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let first = try await daemon.beginPrompt("s", wait: true, queueMaxDepth: 1)
            let second = Task { try await daemon.beginPrompt("s", wait: true, queueMaxDepth: 5) }
            try await nextEvent(waits)
            await #expect(throws: QueueOwnerOverloaded(queued: 1, depth: 1)) {
                try await daemon.beginPrompt("s", wait: true, queueMaxDepth: 5)
            }
            #expect(QueueOwnerOverloaded(queued: 1, depth: 1).localizedDescription
                == "Queue owner is overloaded (1/1 queued)")

            // Once the session has an owner, its depth — 16, here — is the one.
            await daemon.holdAsAnOwner("s", ttlMilliseconds: 60_000)
            let third = Task { try await daemon.beginPrompt("s", wait: true, queueMaxDepth: 1) }
            try await nextEvent(waits)

            #expect(await daemon.endPromptAndLook("s", first) != nil)
            let secondBegun = try await second.value
            #expect(await daemon.endPromptAndLook("s", secondBegun) != nil)
            let thirdBegun = try await third.value
            #expect(await daemon.endPromptAndLook("s", thirdBegun) == nil)
            await daemon.forgetOwner("s")
        }
    }

    /// The depth an owner is started with is its first prompt's, at least 1, and 16 when that
    /// prompt brings none, as acpx normalizes its owner's (`Math.max(1, …)`).
    @Test func anOwnersDepthIsItsFirstPromptsAtLeastOne() async throws {
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        for (brought, kept) in [(Int?.none, 16), (3, 3), (0, 1), (-2, 1)] {
            await daemon.turnStarts("s", ttlMs: nil, queueMaxDepth: brought)
            #expect(await daemon.owners["s"]?.maxQueueDepth == kept, "\(String(describing: brought))")
            await daemon.turnStarts("s", ttlMs: nil, queueMaxDepth: 9)
            #expect(await daemon.owners["s"]?.maxQueueDepth == kept, "a running owner keeps its own")
            await daemon.forgetOwner("s")
        }
    }
}
