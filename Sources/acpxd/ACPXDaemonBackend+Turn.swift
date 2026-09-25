import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

// A turn's exchange with the agent once connected: its prompt, the wait past the
// agent's answer, and what the turn streams to the calling client meanwhile. Split from
// `ACPXDaemonBackend+Prompt.swift` to keep that file inside the 500-line limit.
extension ACPXDaemonBackend {
    /// An attempt's prompt, and whether it was sent. A cancel asked before it went out
    /// ends the turn so, the prompt unsent, as acpx's attempt stops at its aborted turn
    /// (`runPromptWithRetries`) — the user's message kept; one asked from then on waits
    /// for it to go out. Once answered, the turn goes on until the session's updates have
    /// gone quiet, as acpx's does, so that what the agent sends after its answer is part
    /// of it.
    func sendPrompt(
        _ blocks: [ContentBlock], on entry: Live, recordId: String
    ) async throws -> (response: PromptResponse, sent: Bool) {
        guard turns[recordId]?.cancelPending != true else { return (PromptResponse(stopReason: .cancelled), false) }
        await promptGoingOut?(recordId)
        let response = try await entry.session.prompt(blocks)
        turns[recordId]?.prompt = nil
        turns[recordId]?.answered = true
        // A request the agent made meanwhile is the turn's too: answered before the turn
        // ends — under its handlers, counted in its permissions — as one made before it.
        // What the agent sends once it has the answer to it is the turn's as well, so the
        // turn ends only when its updates have gone quiet with no request left open.
        let drain = TurnReplyDrain.current
        repeat {
            try? await entry.agent.connection.waitForSessionUpdateDrain(
                sessionId: entry.session.id, idleMilliseconds: drain.idleMilliseconds,
                timeoutMilliseconds: drain.timeoutMilliseconds)
        } while await entry.agent.connection.waitForRequestsAnswered(sessionId: entry.session.id)
        return (response, true)
    }

    /// What one attempt's event subscription carries, relayed as the turn goes: each of
    /// the session's updates folded into the persister (which debounce-saves the record)
    /// and streamed to the calling client with the agent's requests and the client's
    /// diagnostics, in order. Returns the agent's message text.
    static func relay(
        _ stream: AsyncStream<ConnectionEvent>, of boundSessionId: SessionId, as sessionId: String,
        into persister: TurnPersister, to clientSession: Session?,
        onAnswered: @escaping @Sendable (PromptResponse) async -> Void
    ) async -> String {
        // Accumulate the full streamed text for the MCP result, and fold each
        // update into the persister (which debounce-saves the record as it goes).
        var fullText = ""
        for await event in stream {
            switch event {
            case .update(let note) where note.sessionId == boundSessionId:
                if case .agentMessageChunk(let block) = note.update, let chunk = block.text {
                    fullText += chunk
                }
                await persister.apply(note.update)
                let payload = SessionNotification(sessionId: boundSessionId, update: note.update)
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(payload)))
            case .inboundRequest(let request)
                where request.sessionId == nil || request.sessionId == boundSessionId:
                // The agent's own request (a file write, a permission question), and
                // the client's refusal of it: acpx's formatter prints both, so they
                // stream in order with the updates.
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(request)))
            case .clientOperation(let operation)
                where operation.sessionId == nil || operation.sessionId == boundSessionId:
                // A client-side diagnostic the connection reported mid-turn — a
                // permission refusal that may end the turn (see `CodexCompat`).
                // Streamed in order like an update, so the CLI renders it in place;
                // not part of the conversation history (the wire log has the
                // annotated response).
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: sessionId, data: toJSONValue(operation)))
            case .promptAnswered(let answered, let response) where answered == boundSessionId:
                await onAnswered(response)
            default:
                break
            }
        }
        return fullText
    }

    /// Tell the calling client the turn ended, once it is over: after every update, with
    /// how its permissions went — which decides the CLI's exit code, read once the agent's
    /// requests from the turn are answered and its updates have gone quiet, as acpx reads
    /// them for its result (`toPromptResult`) — and the answer's usage and cost.
    static func announceTheEnd(
        of response: PromptResponse, permissions: PermissionStats, result: PromptResultCapture,
        as sessionId: String, to clientSession: Session?
    ) async {
        await clientSession?.sendLogNotification(
            LogMessage(
                level: .info, logger: sessionId,
                data: toJSONValue(TurnEndedEvent(
                    stopReason: response.stopReason.rawValue, permissions: permissions,
                    usage: result.usage, cost: result.cost))))
    }

    /// What tells the calling client the prompt was answered: in order with the updates
    /// before it — acpx's formatters mark the turn done there — and before what the agent
    /// sends after it. The turn is marked answered first (`markAnswered`), so a cancel
    /// from the moment the client learns of it has nothing to send. How the turn went —
    /// its permissions among it, which may still be asked — comes with its end.
    static func announcingTheAnswer(
        as sessionId: String, to clientSession: Session?, markAnswered: @escaping @Sendable () async -> Void
    ) -> @Sendable (PromptResponse) async -> Void {
        { response in
            await markAnswered()
            await clientSession?.sendLogNotification(
                LogMessage(
                    level: .info, logger: sessionId,
                    data: toJSONValue(TurnAnsweredEvent(answeredStopReason: response.stopReason.rawValue))))
        }
    }
}
