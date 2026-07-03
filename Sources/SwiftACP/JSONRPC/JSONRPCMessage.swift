import Foundation
import JSONFoundation

// The JSON-RPC wire model *and* runtime live in JSONFoundation (2.5.0+):
//
//   JSONFoundation  — `JSONValue`, `JSONSchema`, the `JSONRPCMessage` envelope,
//                     and `JSONRPCError`.
//   JSONRPCPeer     — `JSONRPCPeer` (request↔response correlation + concurrent
//                     dispatch) over the `JSONRPCMessageTransport` seam,
//                     `JSONRPCPeerError`, and the in-memory `LoopbackTransport`
//                     (embedded agents, hermetic tests).
//   JSONRPCWire     — framing codecs (`LineFraming`) and the transport-agnostic
//                     `ProcessLaunch` launch descriptor.
//   JSONRPCSubprocess — `StdioTransport`, the swift-subprocess stdio transport:
//                     `.childProcess` drives a spawned agent (the desktop
//                     spawn-client), `.currentProcess` is the agent side
//                     (`ACPAgentServer.serveStdio`). Gated off iOS/Android,
//                     which can't spawn subprocesses.
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
