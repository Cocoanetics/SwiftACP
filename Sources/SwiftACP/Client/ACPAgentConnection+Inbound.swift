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
        let result = await handleIncomingRequest(method: method, params: params)
        if case .failure(let error) = result {
            publish(.inboundRequest(InboundRequest(
                method: method, sessionId: sessionId, failure: InboundRequest.summary(of: error))))
        }
        return result
    }

    func publish(_ event: ConnectionEvent) {
        for sink in eventSinks.values { sink.yield(event) }
    }
}
