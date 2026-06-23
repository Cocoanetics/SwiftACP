import Foundation

/// A bidirectional line transport: write framed JSON-RPC messages, read inbound
/// ones. ACP frames each message as one UTF-8 line terminated by `\n`.
public protocol MessageTransport: AnyObject, Sendable {
    /// Write a single message. The transport appends the newline terminator.
    func write(_ line: String) throws
    /// The stream of inbound lines (one JSON-RPC message each). Call once.
    func makeInboundStream() -> AsyncThrowingStream<String, Error>
    /// Stop the transport and release resources.
    func close()
}

public enum TransportError: Error, LocalizedError {
    case closed
    case launchFailed(String)
    case notUTF8

    public var errorDescription: String? {
        switch self {
        case .closed: return "Transport is closed"
        case .launchFailed(let reason): return "Failed to launch agent: \(reason)"
        case .notUTF8: return "Message was not valid UTF-8"
        }
    }
}
