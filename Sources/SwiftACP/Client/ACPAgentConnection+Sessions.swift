import Foundation
import JSONFoundation

// Taking a session back — `session/load`, `session/resume` — with the options its reply reports
// as the agent wrote them (#119). Split from `ACPAgentConnection.swift` to keep that file inside
// the 500-line limit.
extension ACPAgentConnection {
    /// The root is registered *before* the request is sent: this actor is reentrant at
    /// the `await`, and an agent handling `session/load` may issue `fs/*` for the very
    /// session being loaded. Registering afterwards would refuse those as an unknown
    /// session. A failed load restores whatever was there before.
    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            var response: LoadSessionResponse = try await send("session/load", request)
            response.configOptionsAsSent = configOptionsAsSent(answering: "session/load", in: request.sessionId)
            sessionOpened?()
            return response
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    public func resumeSession(_ request: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            var response: ResumeSessionResponse = try await send("session/resume", request)
            response.configOptionsAsSent = configOptionsAsSent(answering: "session/resume", in: request.sessionId)
            sessionOpened?()
            return response
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    /// The `configOptions` of the agent's answer to `method` for `sessionId`, as the agent wrote
    /// them — member order, members no schema names, and all — as acpx records them; `nil` without
    /// a wire tap, or when the answer has none.
    func configOptionsAsSent(answering method: String, in sessionId: SessionId) -> WireJSON? {
        rawUpdates?.takeResult(of: method, sessionId: sessionId)?["configOptions"]
    }
}
