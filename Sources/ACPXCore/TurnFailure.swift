import Foundation
import JSONFoundation
import SwiftACP

/// What an error says about itself for acpx's output — the options of acpx's
/// `AcpxOperationalError`. An error that says nothing is a runtime failure.
public protocol OutputErrorMeta: Error {
    /// acpx's output code, e.g. `RUNTIME`; `nil` leaves it to the normalization.
    var outputCode: String? { get }
    var detailCode: String? { get }
    var origin: String? { get }
}

/// acpx's `normalizeOutputError` as its queue owner applies it to a failed turn
/// (`sendQueuedTaskError`): origin `runtime` and detail code
/// `QUEUE_RUNTIME_PROMPT_FAILED` unless the error names its own, and as its `acp` the
/// ACP error the turn's exchange showed (`AcpErrorTracker.match`).
public enum TurnFailure {
    public static func event(for error: Error, shown: AcpErrorPayload?, sessionId: String) -> TurnFailedEvent {
        let meta = error as? OutputErrorMeta
        let acp = shown ?? payload(of: error)
        var outputCode = meta?.outputCode ?? "RUNTIME"
        if outputCode == "RUNTIME", ReconnectFallback.isResourceNotFound(error) { outputCode = "NO_SESSION" }
        let detailCode = meta?.detailCode ?? "QUEUE_RUNTIME_PROMPT_FAILED"
        return TurnFailedEvent(
            outputCode: outputCode, detailCode: detailCode, origin: meta?.origin ?? "runtime",
            message: message(of: error), acp: acp.map(\.jsonValue), shown: shown != nil, sessionId: sessionId)
    }

    /// acpx's `formatErrorMessage`: an agent's error by its message, anything else by
    /// its description.
    public static func message(of error: Error) -> String {
        (error as? JSONRPCErrorBody)?.message ?? error.localizedDescription
    }

    /// acpx's `extractAcpError` on the failure itself: the agent's error response.
    static func payload(of error: Error) -> AcpErrorPayload? {
        guard let rpc = error as? JSONRPCErrorBody else { return nil }
        return AcpErrorPayload(code: Double(rpc.code), message: rpc.message, data: rpc.data.map(WireJSON.init))
    }
}

extension AcpErrorPayload {
    /// `{code, message, data}` — the payload as acpx carries it.
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["code": .double(code), "message": .string(message)]
        if let data { object["data"] = data.jsonValue }
        return .object(object)
    }

    /// The payload from `{code, message, data}`.
    public init?(_ value: JSONValue) {
        guard let parsed = AcpErrorPayload.extract(from: WireJSON(value)) else { return nil }
        self = parsed
    }

    /// acpx's `preferredAcpErrorDetails`: `data.details` when it has any text.
    public var details: String? {
        guard let details = data?["details"]?.stringValue else { return nil }
        let trimmed = details.javaScriptTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AgentLaunchError: OutputErrorMeta {
    public var outputCode: String? { nil }
    public var origin: String? { nil }
}

/// acpx's `AgentDisconnectedError`.
extension AgentDisconnectedError: OutputErrorMeta {
    public var outputCode: String? { "RUNTIME" }
    public var detailCode: String? { "AGENT_DISCONNECTED" }
    public var origin: String? { "acp" }
}

/// acpx's `AgentStartupError`.
extension AgentStartupError: OutputErrorMeta {
    public var outputCode: String? { "RUNTIME" }
    public var detailCode: String? { "AGENT_STARTUP_FAILED" }
    public var origin: String? { "acp" }
}

/// acpx's `AcpMessageLimitError`, which says it is not worth retrying.
extension AcpMessageLimitError: OutputErrorMeta {
    public var outputCode: String? { "RUNTIME" }
    public var detailCode: String? { "ACP_MESSAGE_TOO_LARGE" }
    public var origin: String? { "acp" }
    public var retryable: Bool? { false }
}

/// acpx's `UnsupportedPromptContentError`: a usage error, which exits 2.
extension UnsupportedPromptContentError: OutputErrorMeta {
    public var outputCode: String? { "USAGE" }
    public var detailCode: String? { "UNSUPPORTED_PROMPT_CONTENT" }
    public var origin: String? { "acp" }
}
