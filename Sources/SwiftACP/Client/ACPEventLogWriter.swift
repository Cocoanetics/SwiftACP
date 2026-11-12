#if os(macOS) || os(Linux) || os(Windows)
import Foundation

/// An append-only ACP event log for an in-process ``ACPAgent`` session: each qualifying
/// wire body as one NDJSON line (`WireJSON.stringified` + `"\n"`), flushed per message.
///
/// No session record, journal markers, segment rotation, or `~/.acpx/sessions` paths —
/// the caller chooses the file. A write cut short leaves a partial last line for the
/// reader; this writer does not rotate it away.
public struct ACPEventLogWriter: Sendable {
    private let path: String

    public init(_ url: URL) {
        path = url.path
    }

    /// Append `body` when it is an ACP message (``WireJSON/isACPMessage(_:)``), else leave
    /// the file alone.
    public func append(_ body: Data) throws {
        guard let message = WireJSON(parsing: body), WireJSON.isACPMessage(message) else { return }
        try appendLine(message.stringified + "\n")
    }

    /// Observer for ``RawWireTap``: appends each qualifying body. I/O failures are ignored
    /// so logging never fails the transport.
    public var observer: RawWireTap.Observer {
        let path = path
        return { _, body in
            try? ACPEventLogWriter(path: path).append(body)
        }
    }

    private init(path: String) {
        self.path = path
    }

    /// Durable append: open `O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_CLOEXEC` (no-follow
    /// and close-on-exec omitted on Windows — ucrt has neither), owner-only, write the
    /// line whole, close — one flush per message.
    private func appendLine(_ text: String) throws {
        #if os(Windows)
        let descriptor = Foundation.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        #else
        let descriptor = Foundation.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        #endif
        guard descriptor >= 0 else {
            throw Failure(message: Self.errnoMessage("open"), code: errno)
        }
        defer { close(descriptor) }
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            // Windows `write` takes `UInt32` for the length; POSIX takes `Int`.
            #if os(Windows)
            let written = bytes.withUnsafeBytes {
                Foundation.write(descriptor, $0.baseAddress, UInt32($0.count))
            }
            #else
            let written = bytes.withUnsafeBytes {
                Foundation.write(descriptor, $0.baseAddress, $0.count)
            }
            #endif
            if written < 0 {
                if errno == EINTR { continue }
                throw Failure(message: Self.errnoMessage("write"), code: errno)
            }
            bytes = bytes.dropFirst(Int(written))
        }
    }

    /// errno text for failures: avoid Windows-deprecated `strerror`.
    private static func errnoMessage(_ syscall: String) -> String {
        #if os(Windows)
        return "\(syscall) failed"
        #else
        return String(cString: strerror(errno))
        #endif
    }

    /// A file operation the event log could not complete.
    public struct Failure: LocalizedError, Equatable, Sendable {
        public let message: String
        public var code: Int32?
        public var errorDescription: String? { message }

        public init(message: String, code: Int32? = nil) {
            self.message = message
            self.code = code
        }
    }
}
#endif
