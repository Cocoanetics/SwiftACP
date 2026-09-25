import Foundation
import JSONFoundation

// The session controls — mode, config option, model — and what the agent asks of the
// client while it answers one.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit.
extension ACPAgentConnection {
    public func setMode(_ request: SetSessionModeRequest) async throws {
        try await answeringItsRequests(in: request.sessionId) {
            let _: EmptyResponse = try await send("session/set_mode", request)
        }
    }

    @discardableResult
    public func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws
        -> SetSessionConfigOptionResponse {
        try await answeringItsRequests(in: request.sessionId) {
            try await send("session/set_config_option", request)
        }
    }

    public func setModel(_ request: SetSessionModelRequest) async throws {
        try await answeringItsRequests(in: request.sessionId) {
            let _: EmptyResponse = try await send("session/set_model", request)
        }
    }

    /// Ask the agent to close a session (`session/close`), as acpx's client does: from
    /// now on what the agent asks for it is answered cancelled — a permission question, a
    /// file read or write, starting a command — and what of that is still being served is
    /// ended first, whether a prompt owns it or not.
    public func closeSession(_ request: CloseSessionRequest) async throws {
        cancellingSessionIds.insert(request.sessionId)
        answerSessionRequestsCancelled(request.sessionId)
        let _: EmptyResponse = try await send("session/close", request)
    }

    /// Send a control whose answer can arrive before the answers to what the agent asked
    /// of the client meanwhile. Those of them a prompt would own are answered before this
    /// returns: afterwards they would be handled under whatever handlers the next caller
    /// put in place.
    private func answeringItsRequests<T>(in sessionId: SessionId, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await inboundRequests.waitUntilIdle(sessionId)
            return value
        } catch {
            await inboundRequests.waitUntilIdle(sessionId)
            throw error
        }
    }
}
