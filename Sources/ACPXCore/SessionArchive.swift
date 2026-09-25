import Foundation
import SwiftACP

/// A session as acpx carries it between machines (`src/session/export.ts`,
/// `src/session/import.ts`, 0.19.1): a portable archive, `format_version` 1, of its record
/// and the messages of its event log.
public enum SessionArchive {
    public static let formatVersion = 1

    /// An export or import acpx refuses: a usage error, exit 2, from the CLI, with acpx's
    /// detail code (`SessionExportError`, `SessionImportError`).
    public struct Refusal: LocalizedError, OutputErrorMeta, Equatable {
        public let message: String
        public let detailCode: String?
        public var outputCode: String? { "USAGE" }
        public var origin: String? { "cli" }
        public var errorDescription: String? { message }

        public init(_ message: String, _ detailCode: String) {
            self.message = message
            self.detailCode = detailCode
        }
    }

    /// A failure acpx reports as a plain `Error`: a runtime error.
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        /// The `errno` a file operation failed with, when one did.
        public var code: Int32?
        public var errorDescription: String? { message }
    }

    // MARK: - Export

    /// Write the archive of `record` to `outputPath`, as acpx's `exportSession` writes it:
    /// refused while the session's agent is running.
    ///
    /// - Parameter agentName: the agent the session was looked up by, when it was named —
    ///   the archive's `agent_name`.
    public static func export(
        _ record: SessionRecord, agentName: String?, to outputPath: String,
        home: String = ACPXPaths.home.path, exportedAt: String = nowISO()
    ) throws {
        if try isActive(record) {
            throw Refusal(
                "session is currently locked by a running queue owner; close it first with `acpx sessions close`",
                "session-locked")
        }
        let archive = try archive(of: record, agentName: agentName, home: home, exportedAt: exportedAt)
        try writeFile(Data((archive.stringified(indent: 2) + "\n").utf8), to: try exportTarget(outputPath))
    }

    /// acpx's `ExportedSession` of `record`.
    static func archive(of record: SessionRecord, agentName: String?, home: String, exportedAt: String) throws
        -> WireJSON {
        let cwd = relativeToHome(record.cwd, home: home)
        let session = SessionRecordParser.object([
            ("record_id", .text(record.acpxRecordId)),
            ("name", record.name.map(WireJSON.text) ?? .null),
            ("agent", .text(record.agentCommand)),
            ("agent_name", normalizedAgentName(agentName).map(WireJSON.text)),
            ("cwd_relative", .text(cwd)),
            ("cwd_original", .text(cwd)),
            ("created_at", .text(record.createdAt)),
            ("updated_at", .text(record.lastUsedAt)),
            ("state", try state(of: record, cwd: cwd))
        ])
        return SessionRecordParser.object([
            ("format_version", .number(Double(formatVersion))),
            ("exported_at", .text(exportedAt)),
            ("exported_by", .text("acpx")),
            ("session", session),
            ("history", .array(try history(of: record)))
        ])
    }

    /// The record as acpx writes it (`serializeSessionRecordForArchive`), its `cwd` as the
    /// archive has it and its event log's active file named alone.
    ///
    /// Of SwiftACP's own fields, which acpx does not know, the session's restrictions
    /// (`client_capabilities`) go with it — imported, a session made under `--no-fs` must
    /// not get the filesystem back — but not its MCP servers (`mcp_servers`): their
    /// commands, environment and headers are this machine's, and may hold credentials an
    /// archive must not carry. acpx's archive never has them either. Nor does the
    /// environment the session's agent starts with (`session_options.env`) go: it is
    /// this machine's too, and may hold credentials.
    private static func state(of record: SessionRecord, cwd: String) throws -> WireJSON {
        guard let written = WireJSON(parsing: try SessionRecordSerializer.data(for: record)) else {
            throw Failure(message: "session record could not be serialized")
        }
        var state = written.replacing("cwd", with: .text(cwd))
        if let eventLog = state["event_log"], case .object = eventLog {
            state = state.replacing("event_log", with: eventLog.replacing("active_path", with: .text(".stream.ndjson")))
        }
        if var acpx = state["acpx"], case .object = acpx {
            acpx = acpx.removing("mcp_servers")
            if let options = acpx["session_options"], options.hasMember("env") {
                let kept = options.removing("env")
                acpx = kept == .object([])
                    ? acpx.removing("session_options") : acpx.replacing("session_options", with: kept)
            }
            state = state.replacing("acpx", with: acpx)
        }
        return state
    }

    /// acpx's `listSessionEvents`: the ACP messages of the session's event log, oldest
    /// segment first — each line that `JSON.parse` reads as one. Read as acpx's journal
    /// reads it: every segment's path looked at first, then those there read. One not
    /// there is skipped. Anything else — not a regular file, or unreadable — fails the
    /// export, which would otherwise leave part of the conversation out of an archive.
    static func history(of record: SessionRecord) throws -> [WireJSON] {
        let paths = stride(from: record.eventLog.maxSegments, through: 1, by: -1).map {
            ACPXPaths.sessionStreamSegmentPath(record.acpxRecordId, segment: $0).path
        } + [ACPXPaths.sessionStreamPath(record.acpxRecordId).path]
        return try paths.filter(isPresentSegment).flatMap { path -> [WireJSON] in
            let data: Data
            do {
                data = try readFile(at: path)
            } catch let failure as Failure where failure.code == ENOENT {
                // Gone since it was looked at: acpx's reader takes its snapshot again.
                return []
            }
            // Split on the bytes: as a `String`, "\r\n" is one character, not a line's end.
            return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).compactMap { line in
                guard let value = try? WireJSON.parse(String(decoding: line, as: UTF8.self)), isACPMessage(value)
                else { return nil }
                return value
            }
        }
    }

    /// fs-safe's `statRegularFile`: whether a segment is there, a regular file, or not
    /// (`ENOENT`, `ENOTDIR`). Anything else at its path fails.
    static func isPresentSegment(_ path: String) throws -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return false }
            throw Failure(message: NodePath.errorMessage(code, syscall: "lstat", path: path), code: code)
        }
        guard status.st_mode & S_IFMT == S_IFREG else { throw Failure(message: "path must be a regular file") }
        return true
    }

    /// acpx's `isAcpJsonRpcMessage`: a JSON-RPC 2.0 request, notification or response.
    static func isACPMessage(_ value: WireJSON) -> Bool {
        guard case .object = value, value["jsonrpc"] == .text("2.0") else { return false }
        let hasMethod = value["method"]?.stringValue.map { !$0.isEmpty } ?? false
        let id = value["id"]
        let validId: Bool
        switch id {
        case .null?, .string?: validId = true
        case .number(let number)?: validId = number.isFinite
        default: validId = false
        }
        if hasMethod { return id == nil || validId }
        guard id != nil, validId else { return false }
        switch (value["result"], value["error"]) {
        case (.some, .none): return true
        case (.none, .some(let error)):
            guard case .number(let code)? = error["code"], code.isFinite, case .string? = error["message"] else {
                return false
            }
            return true
        default: return false
        }
    }

    /// acpx's `isSessionActive`: open, with its agent's process alive or the event-log
    /// lock of acpx's queue owner held by a live one. (acpxd takes no such lock.)
    static func isActive(_ record: SessionRecord) throws -> Bool {
        guard record.closed != true else { return false }
        if isProcessAlive(record.pid) { return true }
        let lock: Data
        do {
            lock = try readFile(at: ACPXPaths.sessionStreamLockPath(record.acpxRecordId).path)
        } catch let failure as Failure where failure.code == ENOENT {
            return false
        }
        guard let payload = try? WireJSON.parse(String(decoding: lock, as: UTF8.self)), case .object = payload,
            case .number(let pid)? = payload["pid"]
        else { return false }
        return isProcessAlive(Int(exactly: pid))
    }

    /// acpx's `isProcessAlive`: another process, there to be signalled — one that may not
    /// be (`EPERM`) counts as gone.
    private static func isProcessAlive(_ pid: Int?) -> Bool {
        guard let pid, pid > 0, let processId = Int32(exactly: pid), processId != getpid() else { return false }
        return kill(processId, 0) == 0
    }

    /// Node's `fs.readFile(path)`: the file's bytes, or the error Node gives — its code,
    /// the call that failed and, for `open`, the path.
    static func readFile(at path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw Failure(message: NodePath.errorMessage(code, syscall: "open", path: path), code: code)
        }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count > 0 {
                data.append(buffer, count: count)
            } else if case let code = errno, code != EINTR {
                throw Failure(message: NodePath.errorMessage(code, syscall: "read"), code: code)
            }
        }
    }

    /// acpx's `cwdRelativeToHome`: `cwd` relative to `home` when inside it, `.` for home
    /// itself, and otherwise as it is.
    static func relativeToHome(_ cwd: String, home: String) -> String {
        let relative = NodePath.relative(from: home, to: cwd)
        if relative.isEmpty { return "." }
        if !relative.hasPrefix(".."), !relative.hasPrefix("/") { return relative }
        return cwd
    }

    /// acpx's `normalizeAgentName`: trimmed and lowercased, Factory's droid by its short
    /// name, and none when blank.
    static func normalizedAgentName(_ name: String?) -> String? {
        guard let normalized = name?.javaScriptTrimmed.lowercased(), !normalized.isEmpty else { return nil }
        return normalized == "factory-droid" || normalized == "factorydroid" ? "droid" : normalized
    }

    /// acpx's `resolveExportTarget`: the file `path` names, following symbolic links up to
    /// 40 of them; a path that exists as anything but a file is refused.
    static func exportTarget(_ path: String) throws -> String {
        var path = path
        for _ in 0..<40 {
            var status = stat()
            guard lstat(path, &status) == 0 else {
                if errno == ENOENT { return path }
                throw Failure(message: NodePath.errorMessage(errno, syscall: "lstat", path: path))
            }
            let type = status.st_mode & S_IFMT
            if type == S_IFREG { return path }
            guard type == S_IFLNK, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            else { throw Failure(message: "Session export output must be a regular file") }
            path = target.hasPrefix("/") ? target : "\(NodePath.dirname(path))/\(target)"
        }
        throw Failure(message: "Too many symbolic links in session export output")
    }

    /// acpx's `writePrivateFile`: `data` into `path`'s directory, made as needed — owner
    /// only when `privateDirectory` — through a temporary file only its owner can read.
    static func writeFile(_ data: Data, to path: String, privateDirectory: Bool = false) throws {
        let directory = NodePath.dirname(path)
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: privateDirectory ? [.posixPermissions: 0o700] : nil)
        guard let resolved = realpath(directory, nil) else {
            throw Failure(message: NodePath.errorMessage(errno, syscall: "realpath", path: directory))
        }
        let real = String(cString: resolved)
        free(resolved)
        if privateDirectory { chmod(real, 0o700) }
        try atomicWrite(data, to: URL(fileURLWithPath: real).appendingPathComponent(NodePath.basename(path)))
    }
}
