import Foundation
import SwiftACP

/// A tiny reference ACP agent built on ``ACPServer``: it streams a plan, a tool
/// call, and a word-by-word reply, then returns a stop reason with token usage.
/// It mirrors what a real adapter does, so it doubles as end-to-end protocol
/// validation — drive it with the ACP client:
///
///     acpx --agent "<path>/acp-mock-agent" exec "hello"
final class MockAgentHandler: ACPAgentHandler {
    func initialize(_ request: InitializeRequest) async -> InitializeResponse {
        InitializeResponse(
            agentCapabilities: AgentCapabilities(
                loadSession: false,
                promptCapabilities: PromptCapabilities(image: false, audio: false, embeddedContext: false)),
            agentInfo: Implementation(name: "acp-mock-agent", version: "0.1.0"),
            authMethods: [])
    }

    func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: "mock-\(UUID().uuidString)")
    }

    func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
        let text = request.prompt.compactMap(\.text).joined()

        await session.sendPlan([
            PlanEntry(content: "Read the request", status: .completed),
            PlanEntry(content: "Compose a reply", status: .inProgress)
        ])

        await session.sendToolCall(
            ToolCall(toolCallId: "call-1", title: "echo", kind: .other, status: .inProgress))
        await session.sendToolCallUpdate(ToolCallUpdate(toolCallId: "call-1", status: .completed))

        let reply = "You said: " + text.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in reply.split(separator: " ") {
            if session.isCancelled { return PromptResponse(stopReason: .cancelled) }
            await session.sendText(String(word) + " ")
        }

        return PromptResponse(
            stopReason: .endTurn,
            usage: PromptUsage(inputTokens: 12, outputTokens: 34, totalTokens: 46))
    }
}

@main
enum MockAgentMain {
    static func main() async throws {
        try await ACPAgentServer.serveStdio(handler: MockAgentHandler())
    }
}
