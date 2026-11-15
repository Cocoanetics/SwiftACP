#if os(macOS) || os(Linux) || os(Windows)
import Foundation
#if os(Windows)
import WinSDK
#endif

/// An append-only ACP event log: each qualifying body as `WireJSON.stringified + "\n"`.
/// `timestampIndex` opts into a companion NDJSON index; the default creates only the raw log.
/// Convention: `logURL.appendingPathExtension("timestamps.ndjson")` (pass it explicitly).
///
/// Copies and observers share synchronized state. One logical writer owns the pair;
/// simultaneous independent writers/processes targeting it are unsupported. Copy/archive
/// both files together and discard the index when replacing the raw log.
///
/// Raw bytes are appended first. A crash or index error can leave raw lines without metadata;
/// a partial raw tail is preserved, and an append starting inside it is not indexed.
/// Closing per append is neither a two-file transaction nor an fsync durability guarantee.
public struct ACPEventLogWriter: Sendable {
    private let state: State

    public init(_ url: URL, timestampIndex: URL? = nil) {
        state = State(url: url, timestampIndex: timestampIndex, write: Self.write)
    }

    /// A write seam for deterministic short-write and failure tests, shared by all copies.
    init(_ url: URL, timestampIndex: URL?, write: @escaping Write) {
        state = State(url: url, timestampIndex: timestampIndex, write: write)
    }

    /// Append an ACP message, capturing the local time before parsing; ignore other bodies.
    public func append(_ body: Data) throws {
        try append(body, timestamp: Date())
    }

    /// Append with an explicit observation time and optional client-relative direction.
    /// Throws on I/O failure, including index failure after a successful raw append.
    public func append(_ body: Data, timestamp: Date, direction: ACPEventLogDirection? = nil) throws {
        guard let message = WireJSON(parsing: body), WireJSON.isACPMessage(message) else { return }
        let bytes = Data((message.stringified + "\n").utf8)
        try state.lock.withLock { try state.append(bytes, timestamp: timestamp, direction: direction) }
    }

    /// A standalone observer captures its time when called. I/O errors never fail transport.
    public var observer: RawWireTap.Observer {
        { direction, body in
            try? append(body, timestamp: Date(), direction: direction == .inbound ? .inbound : .outbound)
        }
    }

    /// Launch uses the time captured on entry to `RawWireTap.observe`, before caller callbacks.
    var timestampedObserver: RawWireTap.TimestampedObserver {
        { direction, body, timestamp in
            try? append(body, timestamp: timestamp, direction: direction == .inbound ? .inbound : .outbound)
        }
    }

    /// Reject invalid pairs before any launch probes or process creation. Resolve equivalent
    /// paths and symlinks, and compare existing file identities to catch hard links too.
    static func validate(eventLog: URL?, timestampIndex: URL?) throws {
        guard let timestampIndex else { return }
        guard let eventLog else { throw Failure(message: "A timestamp index requires an event log") }
        let raw = eventLog.standardizedFileURL.resolvingSymlinksInPath()
        let index = timestampIndex.standardizedFileURL.resolvingSymlinksInPath()
        if equivalentPaths(raw, index) || sameFile(raw, index) {
            throw Failure(message: "The event log and timestamp index must target different files")
        }
    }

    private static func equivalentPaths(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.path == rhs.path { return true }
        #if os(Windows)
        let caseSensitive = false
        #else
        // Compare new filenames using their volume's rules too: EVENTS and events can
        // target the same file even when neither exists yet. Find an existing ancestor.
        var ancestor = lhs.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        let values = try? ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? true
        #endif
        return !caseSensitive && lhs.path.caseInsensitiveCompare(rhs.path) == .orderedSame
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        #if os(Windows)
        // CRT stat uses a zero inode; compare the actual Windows volume/file identity.
        guard let left = fileIdentity(lhs), let right = fileIdentity(rhs) else { return false }
        return left == right
        #else
        guard let left = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let right = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let device = left[.systemNumber] as? NSNumber,
              let inode = left[.systemFileNumber] as? NSNumber else { return false }
        return device == right[.systemNumber] as? NSNumber && inode == right[.systemFileNumber] as? NSNumber
        #endif
    }

    #if os(Windows)
    private static func fileIdentity(_ url: URL) -> [DWORD]? {
        // URL paths may use the RFC 8089 /C:/ spelling; Win32 expects C:/.
        let path = url.path
        let nativePath = path.hasPrefix("/") && path.dropFirst(2).first == ":" ? String(path.dropFirst()) : path
        let handle = nativePath.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        return [info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow]
    }
    #endif

    typealias Write = @Sendable (Int32, UnsafeRawBufferPointer) throws -> Int

    /// NSLock guards each complete raw/index append pair, including across writer copies.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let url: URL
        let timestampIndex: URL?
        let write: Write

        init(url: URL, timestampIndex: URL?, write: @escaping Write) {
            self.url = url
            self.timestampIndex = timestampIndex
            self.write = write
        }

        func append(_ bytes: Data, timestamp: Date, direction: ACPEventLogDirection?) throws {
            try validate(eventLog: url, timestampIndex: timestampIndex)
            let raw = try Self.open(url)
            defer { try? raw.handle.close() }
            guard let timestampIndex else {
                try appendAll(bytes, to: raw)
                try raw.handle.close()
                return
            }
            // FileHandle uses 64-bit offsets on POSIX and Windows. Never cache the end.
            let offset = try raw.handle.seekToEnd()
            // A metadata inspection error must still leave raw logging working.
            let boundary = Result {
                guard offset > 0 else { return true }
                let reader = try Self.open(url, access: O_RDONLY, create: false)
                defer { try? reader.handle.close() }
                return try Self.endsWithLF(reader.handle, at: offset)
            }
            try appendAll(bytes, to: raw)
            try raw.handle.close()
            guard try boundary.get() else { return }
            let record = ACPEventLogIndexRecord(
                offset: offset, bytes: bytes, timestamp: timestamp, direction: direction)
            let index = try Self.open(timestampIndex, access: O_RDWR)
            defer { try? index.handle.close() }
            let end = try index.handle.seekToEnd()
            if try !Self.endsWithLF(index.handle, at: end) { try appendAll(Data([0x0A]), to: index) }
            try appendAll(record.line(), to: index)
            try index.handle.close()
        }

        private static func endsWithLF(_ file: FileHandle, at end: UInt64) throws -> Bool {
            guard end > 0 else { return true }
            try file.seek(toOffset: end - 1)
            return try file.read(upToCount: 1) == Data([0x0A])
        }

        /// Keep the CRT descriptor because `FileHandle.fileDescriptor` is unavailable on Windows.
        private struct OpenFile {
            let handle: FileHandle
            let descriptor: Int32
        }

        /// Secure append/create; binary mode prevents Windows from translating LF to CRLF.
        private static func open(_ url: URL, access: Int32 = O_WRONLY, create: Bool = true) throws -> OpenFile {
            let flags = access | O_APPEND | (create ? O_CREAT : 0)
            #if os(Windows)
            let descriptor = Foundation.open(url.path, flags | O_BINARY, 0o600)
            #else
            let descriptor = Foundation.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
            #endif
            guard descriptor >= 0 else { throw ioFailure("open") }
            return OpenFile(
                handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                descriptor: descriptor)
        }

        private func appendAll(_ data: Data, to file: OpenFile) throws {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let remaining = UnsafeRawBufferPointer(rebasing: buffer[offset...])
                    let count = try write(file.descriptor, remaining)
                    guard count > 0, count <= remaining.count else {
                        throw Failure(message: "write made no progress", code: EIO)
                    }
                    offset += count
                }
            }
        }
    }

    /// errno text for failures: avoid Windows-deprecated `strerror`.
    private static func ioFailure(_ syscall: String) -> Failure {
        let code = errno
        #if os(Windows)
        return Failure(message: "\(syscall) failed", code: code)
        #else
        return Failure(message: "\(syscall): \(String(cString: strerror(code)))", code: code)
        #endif
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) throws -> Int {
        while true {
            #if os(Windows)
            let written = Foundation.write(descriptor, buffer.baseAddress, UInt32(min(buffer.count, Int(Int32.max))))
            #else
            let written = Foundation.write(descriptor, buffer.baseAddress, buffer.count)
            #endif
            if written >= 0 { return Int(written) }
            if errno != EINTR { throw ioFailure("write") }
        }
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
