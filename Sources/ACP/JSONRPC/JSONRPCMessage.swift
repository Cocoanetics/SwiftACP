import Foundation
import JSONValue

/// A JSON-RPC 2.0 request/response id: a string or a number.
public enum JSONRPCID: Codable, Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// The `error` member of a JSON-RPC failure response.
public struct JSONRPCErrorBody: Codable, Hashable, Sendable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC codes used when this side reports a failure.
    public static func methodNotFound(_ method: String) -> JSONRPCErrorBody {
        .init(code: -32601, message: "Method not found: \(method)")
    }
    public static func invalidParams(_ message: String) -> JSONRPCErrorBody {
        .init(code: -32602, message: "Invalid params: \(message)")
    }
    public static func internalError(_ message: String) -> JSONRPCErrorBody {
        .init(code: -32603, message: message)
    }
}

extension JSONRPCErrorBody: LocalizedError {
    public var errorDescription: String? {
        // Include the structured `data` (e.g. `{"errorKind":"rate_limit"}`) so the
        // detail an agent attaches there reaches callers — including MCP clients,
        // which surface `error.localizedDescription` as the tool-result text.
        guard let data, data != .null,
            let json = try? String(decoding: JSONEncoder().encode(data), as: UTF8.self)
        else {
            return "JSON-RPC error \(code): \(message)"
        }
        return "JSON-RPC error \(code): \(message) — \(json)"
    }
}

/// One decoded line off the wire. JSON-RPC overloads a single object shape for
/// requests, responses and notifications, so we capture key *presence* and let
/// the dispatcher classify it (mirrors acpx's `isAcpJsonRpcMessage`).
struct IncomingMessage {
    var id: JSONRPCID?
    var method: String?
    var params: JSONValue?
    var hasResult: Bool
    var result: JSONValue?
    var error: JSONRPCErrorBody?

    var isRequest: Bool { method != nil && id != nil }
    var isNotification: Bool { method != nil && id == nil }
    var isResponse: Bool { method == nil && id != nil && (hasResult || error != nil) }

    private enum Keys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    init(line: String) throws {
        guard let data = line.data(using: .utf8) else {
            throw JSONRPCErrorBody.internalError("Message was not valid UTF-8")
        }
        let decoder = JSONDecoder()
        let container = try decoder.decode(RawContainer.self, from: data)
        self.id = container.id
        self.method = container.method
        self.params = container.params
        self.hasResult = container.hasResult
        self.result = container.result
        self.error = container.error
    }

    /// Captures presence of `result` (which may legitimately be `null`).
    private struct RawContainer: Decodable {
        var id: JSONRPCID?
        var method: String?
        var params: JSONValue?
        var hasResult: Bool
        var result: JSONValue?
        var error: JSONRPCErrorBody?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            hasResult = container.contains(.result)
            result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
            error = try container.decodeIfPresent(JSONRPCErrorBody.self, forKey: .error)
        }
    }
}

/// Builds an outgoing wire line. Kept as small helpers so the connection actor
/// stays readable.
enum OutgoingMessage {
    static func request(id: JSONRPCID, method: String, params: JSONValue?) -> JSONValue {
        var object: JSONDictionary = [
            "jsonrpc": .string("2.0"),
            "id": encodeID(id),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(method: String, params: JSONValue?) -> JSONValue {
        var object: JSONDictionary = [
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func response(id: JSONRPCID, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": encodeID(id),
            "result": result
        ])
    }

    static func errorResponse(id: JSONRPCID?, error: JSONRPCErrorBody) -> JSONValue {
        var errorObject: JSONDictionary = [
            "code": .integer(error.code),
            "message": .string(error.message)
        ]
        if let data = error.data { errorObject["data"] = data }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": id.map(encodeID) ?? .null,
            "error": .object(errorObject)
        ])
    }

    private static func encodeID(_ id: JSONRPCID) -> JSONValue {
        switch id {
        case .number(let value): return .integer(value)
        case .string(let value): return .string(value)
        }
    }
}
