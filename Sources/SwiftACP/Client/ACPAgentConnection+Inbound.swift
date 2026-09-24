import Foundation
import JSONFoundation

// The agent's requests to this client, as they arrive: reported on the event stream
// in order with the session's updates, then routed.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit;
// the members this reaches are internal rather than private so both halves can.
extension ACPAgentConnection {
    /// Route one inbound request, reporting its arrival — and its refusal, if the client
    /// refuses it — on the event stream, where they fall into wire order with the
    /// session's updates.
    func serveIncomingRequest(
        method: String, params: JSONValue?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        let sessionId = decodedSessionId(params)
        publish(.inboundRequest(InboundRequest(method: method, sessionId: sessionId)))
        let result = await servingUnlessCancelled(method, params, sessionId: sessionId)
        if case .failure(let error) = result {
            publish(.inboundRequest(InboundRequest(
                method: method, sessionId: sessionId, failure: InboundRequest.summary(of: error))))
        }
        return result
    }

    func publish(_ event: ConnectionEvent) {
        for sink in eventSinks.values { sink.yield(event) }
    }

    /// The ACP SDK's `RequestError.methodNotFound(method)`: how acpx refuses a method it
    /// never registered — one it does not serve, or one whose capability is off.
    static func methodNotFound(_ method: String) -> JSONRPCErrorBody {
        JSONRPCErrorBody(
            code: -32601, message: "\"Method not found\": \(method)", data: .object(["method": .string(method)]))
    }

    /// The ACP SDK's `RequestError.requestCancelled()`: a request its client stopped
    /// serving — closed, or cancelling the session — while the request was in flight.
    static let requestCancelled = JSONRPCErrorBody(code: -32800, message: "Request cancelled")

    /// The ACP SDK's `RequestError.invalidParams(error.format())` for params its schema
    /// rejects: zod's `format()` of the issues as `data`.
    static func invalidParams(issues: JSONValue) -> JSONRPCErrorBody {
        JSONRPCErrorBody(code: -32602, message: "Invalid params", data: issues)
    }

    /// `Invalid params` without issues, for params the schema takes that still cannot be
    /// read.
    static let invalidParams = JSONRPCErrorBody(code: -32602, message: "Invalid params")
}
