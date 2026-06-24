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

        let daemon = ACPXDaemon(inheritAgentStderr: true)
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
}
