@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// Live end-to-end checks against the *real* agents — gated on `ACPX_LIVE_AGENTS=1`
/// because they need the agent CLIs installed + logged in and make real API calls.
/// Run one at a time, e.g.:
///   ACPX_LIVE_AGENTS=1 swift test --filter LiveAgentTests/codex
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ACPX_LIVE_AGENTS"] == "1"))
struct LiveAgentTests {
    private func runAgent(_ agent: String, requiresTokenUsage: Bool) async throws {
        let store = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acpx-live-\(agent)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let original = ACPXPaths.baseDir
        ACPXPaths.baseDir = store
        defer {
            ACPXPaths.baseDir = original
            try? FileManager.default.removeItem(at: store)
        }

        // A small empty cwd so repo-indexing agents (cursor) don't crawl this tree.
        let cwd = store.appendingPathComponent("cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let daemon = ACPXDaemonBackend(inheritAgentStderr: true)
        let id = try await daemon.newSession(agentCommand: agent, cwd: cwd.path)
        let reply = try await daemon.runPrompt(
            sessionId: id, text: "What is 2+2? Reply with only the number, nothing else.")
        let record = try #require(SessionStore.loadRecord(id))

        print(
            """

            ===== \(agent) =====
            reply: \(reply.prefix(120))
            cumulative_token_usage: \(String(describing: record.cumulativeTokenUsage))
            cumulative_cost: \(String(describing: record.cumulativeCost))
            request_token_usage entries: \(record.requestTokenUsage?.count ?? 0)
            """)

        // Every agent should answer the arithmetic.
        #expect(reply.contains("4"))

        // claude and codex report a token breakdown on the prompt response (the
        // data acpx drops); the port captures it. cursor-agent's current ACP
        // build sends no usage at all — bare {stopReason} with no usage field and
        // no usage-bearing notifications — so there is nothing to record for it.
        if requiresTokenUsage {
            #expect(record.cumulativeTokenUsage?.inputTokens != nil)
        }
    }

    @Test func codex() async throws { try await runAgent("codex", requiresTokenUsage: true) }
    @Test func claude() async throws { try await runAgent("claude", requiresTokenUsage: true) }
    @Test func cursor() async throws { try await runAgent("cursor", requiresTokenUsage: false) }

    /// An image attachment, all the way to a real model: `Fixtures/image-probe.png`
    /// shows the code `VX7-QUARTZ-4192` between an orange triangle and a blue circle,
    /// so a reply carrying that code can only have come from the image being seen.
    private func runImageAttachment(_ agent: String) async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/image-probe.png")
        let png = try Data(contentsOf: fixture)

        let store = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acpx-live-image-\(agent)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let original = ACPXPaths.baseDir
        ACPXPaths.baseDir = store
        defer {
            ACPXPaths.baseDir = original
            try? FileManager.default.removeItem(at: store)
        }
        let cwd = store.appendingPathComponent("cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let daemon = ACPXDaemonBackend(inheritAgentStderr: true)
        let id = try await daemon.newSession(agentCommand: agent, cwd: cwd.path)
        let reply = try await daemon.runPrompt(
            sessionId: id,
            text: "Reply with only the code text shown in the attached image, nothing else.",
            blocks: [.image(mimeType: "image/png", data: png.base64EncodedString())])

        print("\n===== \(agent) image attachment =====\nreply: \(reply.prefix(200))")
        #expect(reply.contains("VX7-QUARTZ-4192"))

        // The turn is recorded with the image's type and its data, as acpx 0.19.3 records it.
        let record = try #require(SessionStore.loadRecord(id))
        guard case .user(let message) = try #require(record.messages.first) else {
            Issue.record("first message is not a user message")
            return
        }
        guard case .image(let image) = message.content.last else {
            Issue.record("prompt was not persisted with an image block")
            return
        }
        #expect(image.mimeType?.value == "image/png")
        #expect(image.source == png.base64EncodedString())
    }

    @Test func codexImageAttachment() async throws { try await runImageAttachment("codex") }
    @Test func claudeImageAttachment() async throws { try await runImageAttachment("claude") }
}
