import ACPXCore
import Foundation
import JSONRPCPeer
import SwiftACP

// `--format json` as acpx writes it: the ACP exchange itself, one message per line in
// both directions, each printed as `JSON.stringify` prints the message it parsed
// (`WireJSON`). Ports of `cli/output/json-formatter.ts` (the sanitizer and the
// formatter's `onError`), `acp/jsonrpc-error.ts` (the error line) and the
// `AcpErrorTracker` in `session/execution/runtime.ts` (whether a failure is already on
// the stream).

/// acpx's `JsonMessageSanitizer`: under `--suppress-reads` a read's result and a
/// read-like tool's output are replaced by `[read output suppressed]`; nothing else
/// about the message changes, member order included.
struct JSONMessageSanitizer {
    let suppressReads: Bool
    /// The method of each request still awaiting its response, by direction and id.
    private var requestMethodById: [String: String] = [:]
    /// What each tool has said of itself so far: a later update may omit its title or
    /// kind. A kind of JSON `null` clears an earlier one, as in acpx.
    private var toolStateById: [String: (title: String?, kind: String?)] = [:]

    init(suppressReads: Bool) {
        self.suppressReads = suppressReads
    }

    mutating func sanitize(_ message: WireJSON, direction: JSONRPCPeer.WireDirection) -> WireJSON {
        guard suppressReads else { return message }
        if let response = sanitizeReadResponse(message, direction: direction) { return response }
        if let toolMessage = sanitizeReadToolMessage(message) { return toolMessage }
        trackRequestMethod(message, direction: direction)
        return message
    }

    /// A response to `fs/read_text_file` with its content suppressed; `nil` to carry on.
    /// Any response settles its request.
    private mutating func sanitizeReadResponse(
        _ message: WireJSON, direction: JSONRPCPeer.WireDirection
    ) -> WireJSON? {
        guard let key = Self.correlationKey(message["id"], direction.reversed) else { return nil }
        let hasResult = message.hasMember("result")
        guard hasResult || message.hasMember("error") else { return nil }
        let method = requestMethodById.removeValue(forKey: key)
        guard hasResult, method == "fs/read_text_file", let result = message["result"] else { return nil }
        guard result["content"]?.stringValue != nil else { return message }
        return message.replacing("result", with: result.replacing("content", with: .text(SUPPRESSED_READ_OUTPUT)))
    }

    /// A `tool_call`/`tool_call_update` of a read-like tool with its output suppressed;
    /// `nil` to carry on.
    private mutating func sanitizeReadToolMessage(_ message: WireJSON) -> WireJSON? {
        guard message["method"]?.stringValue == "session/update",
            let params = message["params"], case .object = params,
            let update = params["update"], case .object = update,
            let kind = update["sessionUpdate"]?.stringValue,
            kind == "tool_call" || kind == "tool_call_update",
            let toolCallId = update["toolCallId"]?.stringValue, !toolCallId.isEmpty
        else { return nil }

        var state = toolStateById[toolCallId] ?? (title: nil, kind: nil)
        if let title = update["title"]?.stringValue { state.title = title }
        switch update["kind"] {
        case .string?: state.kind = update["kind"]?.stringValue
        case .null?: state.kind = nil
        default: break
        }
        toolStateById[toolCallId] = state
        guard ToolText.isReadLike(title: state.title, kindName: state.kind) else { return nil }

        var sanitized = update
        if update.hasMember("rawOutput") {
            sanitized = sanitized.replacing(
                "rawOutput", with: .object([.init("content", .text(SUPPRESSED_READ_OUTPUT))]))
        }
        if case .array? = update["content"] {
            sanitized = sanitized.replacing("content", with: .array([
                .object([
                    .init("type", .text("content")),
                    .init("content", .object([
                        .init("type", .text("text")), .init("text", .text(SUPPRESSED_READ_OUTPUT))
                    ]))
                ])
            ]))
        }
        return message.replacing("params", with: params.replacing("update", with: sanitized))
    }

    private mutating func trackRequestMethod(_ message: WireJSON, direction: JSONRPCPeer.WireDirection) {
        guard let method = message["method"]?.stringValue,
            let key = Self.correlationKey(message["id"], direction)
        else { return }
        requestMethodById[key] = method
    }

    /// acpx's `requestCorrelationKey`: the direction the request travelled plus its id,
    /// for string and finite-number ids only.
    static func correlationKey(_ id: WireJSON?, _ direction: JSONRPCPeer.WireDirection) -> String? {
        let idKey: String
        switch id {
        case .string?: idKey = "s:" + (id?.stringified ?? "")
        case .number(let value)? where value.isFinite: idKey = "n:" + WireJSON.javaScriptString(for: value)
        default: return nil
        }
        return "\(direction.name):\(idKey)"
    }
}

extension JSONRPCPeer.WireDirection {
    /// acpx's names for the two directions, as seen from the client.
    var name: String { self == .inbound ? "inbound" : "outbound" }
    var reversed: JSONRPCPeer.WireDirection { self == .inbound ? .outbound : .inbound }
}

/// An ACP error as acpx's `extractAcpError` finds one: `{code, message, data}` on the
/// value itself or nested under `error`, `acp` or `cause`, five levels down.
struct AcpErrorPayload: Equatable {
    var code: Double
    var message: String
    var data: WireJSON?

    static func extract(from value: WireJSON, depth: Int = 0) -> AcpErrorPayload? {
        guard depth <= 5, case .object = value else { return nil }
        if case .number(let code)? = value["code"], code.isFinite,
            let message = value["message"]?.stringValue, !message.isEmpty {
            return AcpErrorPayload(code: code, message: message, data: value["data"])
        }
        for key in ["error", "acp", "cause"] {
            if let nested = value[key], let found = extract(from: nested, depth: depth + 1) { return found }
        }
        return nil
    }

    /// acpx's `outboundAcpErrorMatches`: a failure is this error when its text is, or
    /// contains, the error's `data.details` (or else its message), case-insensitively.
    func matches(failureText: String) -> Bool {
        let details = data?["details"]?.stringValue
        let candidate =
            details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? message
        let normalizedFailure = failureText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedFailure == normalizedCandidate || normalizedFailure.contains(normalizedCandidate)
    }
}

/// acpx's `AcpErrorTracker`: the errors the stream has shown. A failure that matches
/// one is already on screen, so nothing more is printed for it: the agent's latest
/// error response always counts; a refusal the client sent counts when the failure
/// says the same thing.
struct AcpErrorTracker {
    private var latestInbound: AcpErrorPayload?
    private var outbound: [AcpErrorPayload] = []

    mutating func observe(_ message: WireJSON, direction: JSONRPCPeer.WireDirection) {
        guard let error = AcpErrorPayload.extract(from: message) else { return }
        if direction == .inbound {
            latestInbound = error
        } else {
            outbound.append(error)
        }
    }

    func match(failureText: String) -> AcpErrorPayload? {
        latestInbound ?? outbound.last { $0.matches(failureText: failureText) }
    }
}

/// acpx's `buildJsonRpcErrorResponse`: how json mode reports a failure the stream did
/// not already show — a JSON-RPC error response with a `null` id.
enum JSONErrorLine {
    /// `OUTPUT_ERROR_JSONRPC_CODES`.
    static let jsonRPCCodes: [String: Double] = [
        "NO_SESSION": -32002, "TIMEOUT": -32070, "PERMISSION_DENIED": -32071,
        "PERMISSION_PROMPT_UNAVAILABLE": -32072, "EXEC_DISABLED": -32603, "RUNTIME": -32603,
        "USAGE": -32602
    ]

    static func make(
        outputCode: String, detailCode: String? = nil, origin: String? = nil, message: String,
        retryable: Bool? = nil, sessionId: String? = nil, acp: AcpErrorPayload? = nil
    ) -> String {
        // `buildFallbackData`, in its key order, leaving out what is not known.
        var fallback: [WireJSON.Member] = [.init("acpxCode", .text(outputCode))]
        if let detailCode { fallback.append(.init("detailCode", .text(detailCode))) }
        if let origin { fallback.append(.init("origin", .text(origin))) }
        if let retryable { fallback.append(.init("retryable", .bool(retryable))) }
        if let sessionId { fallback.append(.init("sessionId", .text(sessionId))) }

        var error: [WireJSON.Member]
        if let acp, !acp.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = [.init("code", .number(acp.code)), .init("message", .text(acp.message))]
            if let data = merged(acp.data, over: fallback) { error.append(.init("data", data)) }
        } else {
            error = [.init("code", .number(jsonRPCCodes[outputCode] ?? -32603)), .init("message", .text(message))]
            error.append(.init("data", .object(fallback)))
        }
        return WireJSON.object([
            .init("jsonrpc", .text("2.0")), .init("id", .null), .init("error", .object(error))
        ]).stringified
    }

    /// `mergeAcpErrorData`: an object's members spread over the fallback's (keeping
    /// the fallback's positions for shared keys), any other data as it is.
    private static func merged(_ data: WireJSON?, over fallback: [WireJSON.Member]) -> WireJSON? {
        guard let data else { return .object(fallback) }
        guard case .object(let members) = data else { return data }
        var result = fallback
        for member in members {
            if let index = result.firstIndex(where: { $0.key == member.key }) {
                result[index].value = member.value
            } else {
                result.append(member)
            }
        }
        return .object(result)
    }
}
