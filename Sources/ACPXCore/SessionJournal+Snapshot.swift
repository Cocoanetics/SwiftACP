import Foundation

// Reading a session's journal as one capture, as acpx's `SessionJournalReader` does
// (`openSnapshot`, `withSnapshot`, #753): every segment there is opened and so pinned,
// read, and kept only while every path still names the file it did. Rotation renames
// segments; a capture it moved is read again 5 ms later, so no segment is read twice
// or not at all, and none that only looks corrupt mid-rotation fails the read.
extension SessionJournal {
    /// A segment opened for a read, as it was when opened.
    struct OpenSegment {
        let path: String
        let descriptor: Int32
        let identity: FileIdentity
        let size: Int

        /// What it held when opened.
        func contents() throws -> Data {
            var data = Data(count: size)
            var read = 0
            while read < size {
                let count = data.withUnsafeMutableBytes { buffer in
                    pread(descriptor, buffer.baseAddress! + read, size - read, off_t(read))
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SessionJournal.failure("read", path)
                }
                guard count > 0 else { throw SessionJournalError.corrupt("Session journal changed while reading") }
                read += count
            }
            return data
        }
    }

    /// Called once a capture is read, before its paths are looked at again: lets a test
    /// move the segments under a read, as rotation does.
    @TaskLocal static var afterCapture: (@Sendable () throws -> Void)?

    /// `read` on one capture of the segments at `paths`, or `nil` when rotation moved them
    /// while they were opened or read. A corrupt journal found by a read whose segments
    /// held still is corrupt; one found while they moved is nothing yet (acpx's
    /// `WATCH_JOURNAL_CORRUPT` retry). Any other failure is at once.
    static func capture<T>(_ paths: [String], _ read: ([OpenSegment]) throws -> T) throws -> T? {
        guard let segments = try openSegments(paths) else { return nil }
        defer { segments.forEach { _ = Foundation.close($0.descriptor) } }
        let outcome: Result<T, SessionJournalError>
        do {
            outcome = .success(try read(segments))
        } catch let corrupt as SessionJournalError where corrupt.code == SessionJournalError.corruptCode {
            outcome = .failure(corrupt)
        }
        try afterCapture?()
        guard try matches(paths, segments) else { return nil }
        return try outcome.get()
    }

    /// `read` on a capture of the segments at `paths`, captured again 5 ms later while
    /// rotation moves them — for a caller that waits in place.
    static func withSnapshot<T>(_ paths: [String], _ read: ([OpenSegment]) throws -> T) throws -> T {
        while true {
            if let value = try capture(paths, read) { return value }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Every segment at `paths` that is there, opened, or `nil` when one moved meanwhile.
    private static func openSegments(_ paths: [String]) throws -> [OpenSegment]? {
        var segments: [OpenSegment] = []
        do {
            for path in paths where try SessionArchive.isPresentSegment(path) {
                segments.append(try open(path))
            }
            if try matches(paths, segments) { return segments }
        } catch let failure as SessionArchive.Failure where failure.code == ENOENT {
            // Renamed away between looking and opening.
        } catch {
            segments.forEach { _ = Foundation.close($0.descriptor) }
            throw error
        }
        segments.forEach { _ = Foundation.close($0.descriptor) }
        return nil
    }

    /// Whether each of `paths` still names the file opened for it, or none when none was.
    private static func matches(_ paths: [String], _ segments: [OpenSegment]) throws -> Bool {
        let opened = Dictionary(segments.map { ($0.path, $0.identity) }, uniquingKeysWith: { first, _ in first })
        return try paths.allSatisfy { try FileIdentity(ofPath: $0) == opened[$0] }
    }

    /// Open the segment at `path`, refusing a symbolic link as acpx's `symlinks: "reject"` does.
    private static func open(_ path: String) throws -> OpenSegment {
        let descriptor = Foundation.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw SessionJournal.failure("open", path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let failure = SessionJournal.failure("fstat", path)
            _ = Foundation.close(descriptor)
            throw failure
        }
        return OpenSegment(
            path: path, descriptor: descriptor, identity: FileIdentity(status), size: Int(status.st_size))
    }
}
