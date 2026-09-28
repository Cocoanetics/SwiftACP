import Foundation
import JSONFoundation
import JSONRPCWire

// Taking a session back — `session/load`, `session/resume` — and the answers acpx records as the
// agent wrote them (#119). Split from `ACPAgentConnection.swift` to keep that file inside the
// 500-line limit.
extension ACPAgentConnection {
    /// The root is registered *before* the request is sent: this actor is reentrant at
    /// the `await`, and an agent handling `session/load` may issue `fs/*` for the very
    /// session being loaded. Registering afterwards would refuse those as an unknown
    /// session. A failed load restores whatever was there before.
    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            let response: LoadSessionResponse = try await sendKeepingConfigOptions("session/load", request)
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
            let response: ResumeSessionResponse = try await sendKeepingConfigOptions("session/resume", request)
            sessionOpened?()
            return response
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    /// ``send(_:_:)``, with the answer's `result` as the agent wrote it, when a wire tap read it:
    /// what acpx records member for member (#119). The request is known by its id as the peer
    /// sends it (``KeptAnswer``), and whatever becomes of the call, its answer is kept no longer.
    func sendKeepingAnswer<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> (R, WireJSON?) {
        let answer = KeptAnswer()
        defer { if let id = answer.id { _ = rawUpdates?.takeAnswer(to: id) } }
        let response: R = try await KeptAnswer.$current.withValue(answer) { try await send(method, params) }
        return (response, answer.id.flatMap { rawUpdates?.takeAnswer(to: $0) })
    }

    /// ``sendKeepingAnswer(_:_:)`` for a reply with config options: those, as the agent wrote them,
    /// go with it (``ConfigOptionsReply/configOptionsAsSent``).
    func sendKeepingConfigOptions<P: Encodable, R: Decodable & ConfigOptionsReply>(
        _ method: String, _ params: P
    ) async throws -> R {
        let (reply, written): (R, WireJSON?) = try await sendKeepingAnswer(method, params)
        var kept = reply
        kept.configOptionsAsSent = written?["configOptions"]
        return kept
    }
}

/// A request whose answer the wire tap keeps as the agent writes it: known by its id once the peer
/// sends it, which the connection's wire hook notes for the request sent under ``current``.
final class KeptAnswer: @unchecked Sendable {
    @TaskLocal static var current: KeptAnswer?

    private let lock = NSLock()
    private var sentId: JSONRPCID?

    /// The request's id, once it has gone out.
    var id: JSONRPCID? { lock.withLock { sentId } }

    func sent(_ id: JSONRPCID) {
        lock.withLock { sentId = id }
    }
}

/// A reply whose `configOptions` acpx records as the agent wrote them (#119).
protocol ConfigOptionsReply {
    var configOptionsAsSent: WireJSON? { get set }
}

extension NewSessionResponse: ConfigOptionsReply {}
extension LoadSessionResponse: ConfigOptionsReply {}
extension SetSessionConfigOptionResponse: ConfigOptionsReply {}
