import Foundation
import JSONFoundation
import SwiftMCP

/// What a failed tool call says beyond its message: what acpx's output reports of the
/// failure (`normalizeOutputError`) — its output code, detail code and origin, whether it
/// may be retried, and the JSON-RPC error it is. acpxd sends it with the tool's error result,
/// as the result's `_meta` under ``metaKey``, so its CLI reports the failure as acpx reports
/// it where it arose: in JSON output, an agent's error by the agent's own code, message and
/// data (#171).
///
/// Each field is what the failure says of itself, `nil` where it says nothing: the CLI
/// normalizes the rest as acpx's does.
public struct ToolFailure: Codable, Sendable, Equatable {
    /// The `_meta` key the failure goes under.
    public static let metaKey = "acpx/error"

    /// acpx's output code: `RUNTIME`, `NO_SESSION`, `TIMEOUT`, …
    public var outputCode: String?
    /// acpx's detail code, e.g. `QUEUE_CONTROL_REQUEST_FAILED`.
    public var detailCode: String?
    /// Where the failure arose: `queue`, `acp`, …
    public var origin: String?
    /// Whether trying again may succeed, when the failure says — acpx's `retryable`.
    public var retryable: Bool?
    /// The JSON-RPC error the failure is, as `{code, message, data}`, when it is one.
    public var acp: JSONValue?

    public init(
        outputCode: String? = nil, detailCode: String? = nil, origin: String? = nil, retryable: Bool? = nil,
        acp: JSONValue? = nil
    ) {
        self.outputCode = outputCode
        self.detailCode = detailCode
        self.origin = origin
        self.retryable = retryable
        self.acp = acp
    }

    /// The failure an error result's `_meta` carries, if it carries one.
    public init?(meta: JSONDictionary) {
        guard let value = meta[Self.metaKey], let failure = try? value.decoded(ToolFailure.self) else { return nil }
        self = failure
    }

    /// Whether it says nothing beyond the message.
    public var isEmpty: Bool { self == ToolFailure() }

    /// The failure as an error result's `_meta`.
    public var meta: JSONDictionary {
        guard let value = try? JSONValue(encoding: self) else { return [:] }
        return [Self.metaKey: value]
    }
}

/// A tool's failure as the tool reports it: by the failure's own message, which every MCP
/// client reads, and what it says beyond that (``ToolFailure``) as the result's `_meta`.
struct DescribedToolFailure: LocalizedError, MCPToolErrorMetaProviding {
    let underlying: Error
    let failure: ToolFailure

    var errorDescription: String? { underlying.localizedDescription }
    var toolErrorMeta: JSONDictionary { failure.meta }
}
