import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

/// A `JSONRPCMessageTransport` over the process's *own* stdio — the agent side of ACP.
///
/// An ACP agent is spawned by its client and speaks JSON-RPC over the stdin it
/// receives and the stdout it writes. JSONFoundation's zero-dep stdio transport
/// (`JSONRPCStdio.ProcessTransport`) only drives a *child* process; the
/// "be the process" direction lives solely in the trait-gated
/// `JSONRPCSubprocess` module. To stay dependency-light, SwiftACP keeps this small
/// transport, but defers framing and JSON coding to the shared
/// `JSONRPCWire.LineFraming` + `JSONRPCMessage` so it carries no wire logic of its
/// own. It mirrors `ProcessTransport`'s reader (a dedicated thread doing buffered
/// blocking reads, for fast token-by-token streaming) but binds to
/// `FileHandle.standardInput` / `.standardOutput` instead of a child's pipes.
///
/// - Important: stdout must carry JSON-RPC *only*. Route the agent's own logs to
///   stderr, or the client will see them as protocol noise.
public final class StdioTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let framing = LineFraming()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, Error> {
        let framing = self.framing
        return AsyncThrowingStream { continuation in
            let handle = input
            let thread = Thread {
                var decoder = framing
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF: client closed our stdin
                    for body in decoder.push(chunk) {
                        if let message = try? JSONRPCMessage.decodeMessages(from: body).first {
                            continuation.yield(message)
                        }
                    }
                }
                continuation.finish()
            }
            thread.name = "acp.stdio.reader"
            thread.stackSize = 4 << 20
            thread.start()

            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        let framed = framing.frame(try message.encoded())
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw JSONRPCPeerError.closed }
        try output.write(contentsOf: framed)
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        // The fds are the process's own stdin/stdout — mark closed but don't shut
        // them; the read thread ends when the client closes our stdin (EOF).
        isClosed = true
    }
}
