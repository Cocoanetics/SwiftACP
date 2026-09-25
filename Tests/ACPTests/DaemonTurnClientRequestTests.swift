@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A turn's own requests reach the calling client in text output too (#141), as acpx's
/// text output shows them — `[client] session/set_config_option (running)` for its
/// `--model` — and before anything the prompt says.
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnsModelRequestIsShownBeforeWhatThePromptSays() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let client = CallingClient()
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(), model: "b", client: client)
            #expect(client.kinds.filter { $0.contains("set_config_option") || $0.hasPrefix("update:") } == [
                "wire:outbound:session/set_config_option", "update:hello"
            ])
            await daemon.releaseAll()
        }
    }
}
