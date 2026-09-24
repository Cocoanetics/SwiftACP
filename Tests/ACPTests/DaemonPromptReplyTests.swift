@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// The CLI's side of a daemon turn over a real MCP proxy — an in-process loopback to
/// the daemon's server — rather than the backend directly: what the CLI gets back is
/// what SwiftMCP's typed client makes of the tool result.
extension DaemonToolsTests {
    /// A prompt the mock echoes back, so its reply holds a newline and quotes — as
    /// nearly every real reply does.
    private static let multiLinePrompt = "line one\nsay \"two\""

    /// Runs `body` against the daemon's MCP server over a loopback, with a session
    /// created on the mock agent.
    ///
    /// The loopback drops the server's log notifications (its session has no way back
    /// to the client), so these tests assert what the daemon recorded, not what the CLI
    /// rendered — rendering is untouched by the workaround they cover.
    private func withLoopbackDaemon(
        _ body: (_ proxy: MCPServerProxy, _ sessionId: String, _ stopReason: StopReasonBox) async throws -> Void
    ) async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let sessionId = try await backend.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let proxy = MCPServerProxy(config: .stdioHandles(server: ACPXDaemon(backend: backend)))
            try await proxy.connect()
            do {
                try await body(proxy, sessionId, StopReasonBox())
            } catch {
                await proxy.disconnect()
                throw error
            }
            await proxy.disconnect()
        }
    }

    private func runTurn(
        on proxy: MCPServerProxy, _ stopReason: StopReasonBox, sessionId: String
    ) async throws -> DaemonTurn {
        try await DaemonClient.runPrompt(
            on: proxy, stopReason: stopReason, sessionId: sessionId,
            content: [.object(["type": .string("text"), "text": .string(Self.multiLinePrompt)])], wait: true,
            permissionMode: "approve-all", nonInteractivePermissions: "deny")
    }

    /// The turn succeeds although the tool's plain-text result cannot be decoded (see
    /// the known issue below): the CLI ignores that text, and the daemon ran the turn
    /// to the end — its reply is in the session's history.
    @Test(.enabled(if: mockPythonAvailable))
    func aReplyWithNewlinesAndQuotesDoesNotFailTheTurn() async throws {
        try await withLoopbackDaemon { proxy, sessionId, stopReason in
            _ = try await runTurn(on: proxy, stopReason, sessionId: sessionId)
            let record = try #require(SessionStore.loadRecord(sessionId))
            let replies = record.messages.flatMap { message -> [String] in
                guard case .agent(let agent) = message else { return [] }
                return agent.content.compactMap { if case .text(let text) = $0 { text } else { nil } }
            }
            #expect(replies.joined().contains(Self.multiLinePrompt))
        }
    }

    /// Only the ignored text is excused: a turn the daemon refuses still fails.
    @Test(.enabled(if: mockPythonAvailable))
    func aRefusedTurnStillFails() async throws {
        try await withLoopbackDaemon { proxy, _, stopReason in
            await #expect(throws: MCPServerProxyError.self) {
                _ = try await runTurn(on: proxy, stopReason, sessionId: "no-such-session")
            }
        }
    }

    /// SwiftMCP's typed client decodes a plain-text `String` result by wrapping it in
    /// quotes without escaping it, so a reply with a newline or a quote fails to decode.
    /// When SwiftMCP fixes that, this known issue stops occurring — and the workaround in
    /// `DaemonClient.runPrompt(on:…)` can go.
    @Test(.enabled(if: mockPythonAvailable))
    func swiftMCPsTypedClientCannotDecodeSuchAReply() async throws {
        try await withLoopbackDaemon { proxy, sessionId, _ in
            await withKnownIssue("SwiftMCP quotes a plain-text String result without escaping it") {
                _ = try await ACPXDaemon.Client(proxy: proxy).runPrompt(
                    sessionId: sessionId, text: Self.multiLinePrompt, blocks: nil, wait: true,
                    permissionMode: "approve-all", nonInteractivePermissions: "deny")
            }
        }
    }
}
