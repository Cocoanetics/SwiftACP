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
//   JSONRPCSubprocess — `StdioMessageTransport`, the swift-subprocess child stdio
//                     transport the desktop spawn-client uses (gated off iOS/Android,
//                     which can't spawn subprocesses).
//
// SwiftACP no longer hand-rolls any of this. These modules are re-exported so a
// consumer of SwiftACP keeps seeing the peer/transport/launch types through a
// single `import SwiftACP`, exactly as when they were defined here.
@_exported import JSONRPCPeer
@_exported import JSONRPCWire
#if os(macOS) || os(Linux) || os(Windows)
@_exported import JSONRPCSubprocess
#endif

/// `JSONRPCErrorBody` is retained as a source-compatibility alias for SwiftACP's
/// existing call sites — it is JSONFoundation's `JSONRPCError` (same
/// `code`/`message`/`data: JSONValue?` shape, `Error`/`LocalizedError`
/// conformance, and `.methodNotFound`/`.invalidParams`/`.internalError`
/// factories).
public typealias JSONRPCErrorBody = JSONRPCError
