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
    /// of it. The answer is waited for within `timeout` (``answer(to:on:recordId:within:)``).
    func sendPrompt(
        _ blocks: [ContentBlock], on entry: Live, recordId: String, within timeout: Int? = nil
    ) async throws -> (response: PromptResponse, sent: Bool) {
        guard turns[recordId]?.cancelPending != true else { return (PromptResponse(stopReason: .cancelled), false) }
        await promptGoingOut?(recordId)
        let (response, recovered) = try await answer(to: blocks, on: entry, recordId: recordId, within: timeout)
        turns[recordId]?.prompt = nil
        turns[recordId]?.answered = true
        // An answer that came while a timed-out prompt's updates went quiet stands as it
        // is, as acpx's `recoveredSessionResult` does: they have gone quiet already.
        if recovered { return (response, true) }
        // A request the agent made meanwhile is the turn's too: answered before the turn
        // ends — under its handlers, counted in its permissions — as one made before it.
        // What the agent sends once it has the answer to it is the turn's as well, so the
        // turn ends only when its updates have gone quiet with no request answered since
        // they did: none came since the last look — one answered already may not have
        // reached the agent yet — and none was still open, whenever it came.
        let (connection, sessionId) = (entry.agent.connection, entry.session.id)
        let drain = TurnReplyDrain.current
        await beforeReplyDrain?(recordId)
        var arrived = await connection.requestsArrived(sessionId: sessionId)
        while true {
            try? await connection.waitForSessionUpdateDrain(
                sessionId: sessionId, idleMilliseconds: drain.idleMilliseconds,
                timeoutMilliseconds: drain.timeoutMilliseconds)
            await afterUpdateDrain?(recordId)
            let waited = await connection.waitForRequestsAnswered(sessionId: sessionId)
            let now = await connection.requestsArrived(sessionId: sessionId)
            if now == arrived, !waited { break }
            arrived = now
        }
        return (response, true)
    }

    /// How long acpx waits for a prompt it cancels to settle before it closes the client
    /// (`INTERRUPT_CANCEL_WAIT_MS`).
    static let cancelWaitMilliseconds = 2_500

    /// The prompt's answer within `timeout` — acpx's `runPromptTurn`. Past the deadline
    /// the prompt's own requests end (``ACPAgentConnection/abandonTurnRequests(sessionId:)``),
    /// but the prompt stays out while the session's updates go quiet, and an answer that
    /// came meanwhile stands (`recovered`). Otherwise the prompt is cancelled, given a
    /// moment to settle, and its agent let go — acpx's `cleanupPrompt` retires a client
    /// whose prompt is still out, so the next turn connects afresh — and the turn fails
    /// with ``TimeoutError``.
    private func answer(
        to blocks: [ContentBlock], on entry: Live, recordId: String, within timeout: Int?
    ) async throws -> (response: PromptResponse, recovered: Bool) {
        let session = entry.session
        guard let timeout, timeout > 0 else { return (try await session.prompt(blocks), false) }
        let settled = SettledAnswer()
        let prompting = Task {
            let response = try await session.prompt(blocks)
            settled.settle(response)
            return response
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await withTimeout(milliseconds: timeout) { try await prompting.value }
            } onCancel: {
                prompting.cancel()
            }
            return (response, false)
        } catch let timedOut as TimeoutError {
            let connection = entry.agent.connection
            await connection.abandonTurnRequests(sessionId: session.id)
            let drain = TurnReplyDrain.current
            try? await connection.waitForSessionUpdateDrain(
                sessionId: session.id, idleMilliseconds: drain.idleMilliseconds,
                timeoutMilliseconds: drain.timeoutMilliseconds)
            if let response = settled.response { return (response, true) }
            try? await connection.cancel(sessionId: session.id)
            _ = try? await withTimeout(milliseconds: Self.cancelWaitMilliseconds) { try await prompting.value }
            if live[recordId]?.agent === entry.agent { live.removeValue(forKey: recordId) }
            await entry.agent.close()
            throw timedOut
        }
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
        // No answer crossed the wire: the turn was cancelled before its prompt went out, or
        // between attempts at it — nothing marks it done.
        let unanswered: Bool? = result.result == nil ? true : nil
        await clientSession?.sendLogNotification(
            LogMessage(
                level: .info, logger: sessionId,
                data: toJSONValue(TurnEndedEvent(
                    stopReason: response.stopReason.rawValue, permissions: permissions,
                    usage: result.usage, cost: result.cost, unanswered: unanswered))))
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

/// A prompt's answer once it has come — looked at without waiting for it.
final class SettledAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: PromptResponse?

    func settle(_ response: PromptResponse) {
        lock.withLock { settled = response }
    }

    var response: PromptResponse? {
        lock.withLock { settled }
    }
}
