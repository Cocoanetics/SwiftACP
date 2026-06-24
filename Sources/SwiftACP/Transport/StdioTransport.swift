import Foundation

/// A `MessageTransport` over the process's *own* stdio — the agent side of ACP.
///
/// An ACP agent is spawned by its client and speaks JSON-RPC over the stdin it
/// receives and the stdout it writes. This mirrors ``SubprocessTransport``'s
/// reader (a dedicated thread doing buffered blocking reads, for fast
/// token-by-token streaming) but binds to `FileHandle.standardInput` /
/// `.standardOutput` instead of a child's pipes.
///
/// - Important: stdout must carry JSON-RPC *only*. Route the agent's own logs to
///   stderr, or the client will see them as protocol noise.
public final class StdioTransport: MessageTransport, @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
    }

    public func makeInboundStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = input
            let thread = Thread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF: client closed our stdin
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex ..< newline]
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        if lineData.isEmpty { continue }
                        if let line = String(data: lineData, encoding: .utf8) {
                            continuation.yield(line)
                        }
                    }
                }
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
                    !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.yield(line)
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

    public func write(_ line: String) throws {
        guard var data = line.data(using: .utf8) else { throw TransportError.notUTF8 }
        data.append(0x0A) // newline frame terminator
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw TransportError.closed }
        try output.write(contentsOf: data)
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        // The fds are the process's own stdin/stdout — mark closed but don't shut
        // them; the read thread ends when the client closes our stdin (EOF).
        isClosed = true
    }
}
