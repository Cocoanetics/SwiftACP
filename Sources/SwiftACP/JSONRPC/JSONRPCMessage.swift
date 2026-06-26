import Foundation
import JSONFoundation

/// `JSONRPCID`, `JSONRPCMessage` and the JSON-RPC error payload all come from
/// `JSONFoundation` (the shared, dependency-free JSON-RPC types). SwiftACP no
/// longer hand-rolls wire parsing/encoding — `JSONRPCConnection` decodes inbound
/// lines with `JSONRPCMessage.decodeMessages(from:)` and classifies them via the
/// message accessors, and encodes outbound with `JSONRPCMessage.encodedString()`.
///
/// `JSONRPCErrorBody` is retained as a source-compatibility alias for SwiftACP's
/// existing call sites — it is JSONFoundation's `JSONRPCError` (same
/// `code`/`message`/`data: JSONValue?` shape, `Error`/`LocalizedError`
/// conformance, and `.methodNotFound`/`.invalidParams`/`.internalError`
/// factories).
public typealias JSONRPCErrorBody = JSONRPCError
