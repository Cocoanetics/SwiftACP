import Foundation
import JSONFoundation

// The JSON-RPC wire model *and* runtime now live in JSONFoundation (2.1.0+):
//
//   JSONFoundation  — `JSONValue`, `JSONSchema`, the `JSONRPCMessage` envelope,
//                     and `JSONRPCError`.
//   JSONRPCPeer     — `JSONRPCPeer` (request↔response correlation + concurrent
//                     dispatch) over the `JSONRPCMessageTransport` seam, plus
//                     `JSONRPCPeerError`.
//   JSONRPCWire     — framing codecs (`LineFraming`) and the transport-agnostic
//                     `ProcessLaunch` launch descriptor.
//   JSONRPCStdio    — `ProcessTransport`, the zero-dep `Foundation.Process` stdio
//                     transport (with `ProcessExit`).
//
// SwiftACP no longer hand-rolls any of this. These modules are re-exported so a
// consumer of SwiftACP keeps seeing the peer/transport/launch types through a
// single `import SwiftACP`, exactly as when they were defined here.
@_exported import JSONRPCPeer
@_exported import JSONRPCStdio
@_exported import JSONRPCWire

/// `JSONRPCErrorBody` is retained as a source-compatibility alias for SwiftACP's
/// existing call sites — it is JSONFoundation's `JSONRPCError` (same
/// `code`/`message`/`data: JSONValue?` shape, `Error`/`LocalizedError`
/// conformance, and `.methodNotFound`/`.invalidParams`/`.internalError`
/// factories).
public typealias JSONRPCErrorBody = JSONRPCError
