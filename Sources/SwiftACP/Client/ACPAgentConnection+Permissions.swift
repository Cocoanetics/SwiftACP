import Foundation
import JSONFoundation

// Answering the agent's `session/request_permission`: the handler's answer, the
// adapter-compatibility rules around it, and the turn's permission stats.
//
// Split from `ACPAgentConnection.swift` to keep each file inside the 500-line limit.
extension ACPAgentConnection {
    // MARK: - Permission requests

    /// Answer a `session/request_permission` through the configured handler, with
    /// the adapter-compatibility rules acpx applies at the client boundary (see
    /// ``CodexCompat``): Codex's non-aborting refusal is ranked first before the
    /// handler picks, and a refusal that may still end the turn is explained — as a
    /// ``ClientOperation`` on the event subscriptions (ahead of anything the agent
    /// sends in reaction) and as `_meta.acpx.permissionNotice` on the response.
    /// Nothing here approves an operation to keep a turn running.
    func resolvePermission(
        _ request: RequestPermissionRequest,
        with handler: @Sendable (RequestPermissionRequest) async throws -> RequestPermissionResponse
    ) async throws -> RequestPermissionResponse {
        let response: RequestPermissionResponse
        var promptUnavailable = false
        do {
            response = try await answerPermission(request, with: handler)
        } catch is PermissionPromptUnavailableError {
            // acpx's `handleModePermissionError`: answered `cancelled`, and noted, so
            // the turn fails on it once over.
            response = RequestPermissionResponse(outcome: .cancelled)
            promptUnavailable = true
        }
        // Every answer is counted, whichever way it was reached — acpx's
        // `finishPermissionRequest` classifies the response that actually went back.
        turnPermissionStats[request.sessionId, default: PermissionStats()]
            .record(PermissionStats.classify(request, response))
        if promptUnavailable { turnPermissionStats[request.sessionId]?.promptUnavailable = true }
        return response
    }

    private func answerPermission(
        _ request: RequestPermissionRequest,
        with handler: @Sendable (RequestPermissionRequest) async throws -> RequestPermissionResponse
    ) async throws -> RequestPermissionResponse {
        let agentName = initializeResult?.agentInfo?.name
        // Ahead of the handler: an Antigravity interaction question has no answer any
        // policy may give on the user's behalf, so it is cancelled rather than resolved.
        if AntigravityCompat.isInteractionQuestion(request, agentName: agentName) {
            let notice = AntigravityCompat.questionNotice
            announce(notice, sessionId: request.sessionId)
            return RequestPermissionResponse(outcome: .cancelled)
                .addingACPXMetadata(["permissionNotice": .string(notice)])
        }
        let response = try await handler(CodexCompat.preferPermissionRefusal(request, agentName: agentName))
        if let escalation = response.permissionEscalation {
            announce(escalation.message, sessionId: request.sessionId, escalation: escalation)
        }
        guard let notice = CodexCompat.permissionNotice(
            request: request, response: response, agentName: agentName),
            !cancellingSessionIds.contains(request.sessionId),
            !isDeliberateCancellation(request, response)
        else { return response }
        announce(notice, sessionId: request.sessionId)
        return response.addingACPXMetadata(["permissionNotice": .string(notice)])
    }

    /// Report a permission notice to the event subscriptions, ahead of anything the
    /// agent sends in reaction to the answer.
    private func announce(_ notice: String, sessionId: SessionId, escalation: PermissionEscalation? = nil) {
        let operation = ClientOperation(
            method: ClientOperation.requestPermission, status: .completed, summary: notice,
            sessionId: sessionId, escalation: escalation)
        for sink in eventSinks.values {
            sink.yield(.clientOperation(operation))
        }
    }

    /// Whether a handler cancelled outright although the agent offered a refusal it
    /// could have selected — acpx's explicit host `cancel` decision, which needs no
    /// explaining. The built-in policies only cancel when no refusal exists at all.
    private func isDeliberateCancellation(
        _ request: RequestPermissionRequest, _ response: RequestPermissionResponse
    ) -> Bool {
        guard case .cancelled = response.outcome else { return false }
        return request.options.contains { $0.kind == .rejectOnce || $0.kind == .rejectAlways }
    }
}
