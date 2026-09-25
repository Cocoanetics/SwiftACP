@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A daemon turn's usage goes to its own prompt, as acpx 0.19.1 records it
/// (`recordPromptResponseUsage` with the prompt's message id), even when the agent echoes
/// the prompt back as a user message of its own before it answers (#154).
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnsUsageGoesToItsOwnPrompt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            try session.set("echo-usage")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(), client: CallingClient())

            let record = try #require(SessionStore.loadRecord(session.id))
            let userIds = record.messages.compactMap { message -> String? in
                if case .user(let user) = message { return user.id }
                return nil
            }
            #expect(userIds.count == 2)
            #expect(record.requestTokenUsage?.keys.sorted() == [try #require(userIds.first)])
            #expect(record.requestTokenUsage?[try #require(userIds.first)]?.inputTokens == 11)
            await daemon.releaseAll()
        }
    }
}
