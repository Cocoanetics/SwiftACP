import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import JSONFoundation

/// Callbacks the agent may invoke on the client during a turn.
///
/// These are the client-side ACP methods. Supplying `nil` for one means the
/// corresponding capability is unavailable (and, for the request/response ones,
/// the agent receives a "method not found" error).
public struct ACPClientHandlers: Sendable {
    /// Decide the outcome of a tool-call permission request. Called when the
    /// agent wants approval for a tool call; return the selected option, or
    /// `.cancelled` if the turn ended without a choice.
    ///
    /// The connection hands over the request with its adapter-compatibility ranking
    /// applied (Codex's non-aborting refusal first — see ``CodexCompat``), and
    /// explains a refusal that may end the turn on the way back. Throw
    /// ``PermissionPromptUnavailableError`` for a request that needed a question no one
    /// could be asked: it is answered `cancelled`, and the turn fails on it.
    public var requestPermission:
        (@Sendable (RequestPermissionRequest) async throws -> RequestPermissionResponse)?
    /// Serve `fs/read_text_file`: return file content, honouring `line`/`limit`.
    public var readTextFile: (@Sendable (ReadTextFileRequest) async throws -> ReadTextFileResponse)?
    /// Serve `fs/write_text_file`: write the given content to the given path.
    public var writeTextFile:
        (@Sendable (WriteTextFileRequest) async throws -> WriteTextFileResponse)?
    /// Authorize an `fs/write_text_file` before anything on disk is touched — acpx's
    /// `isWriteApproved`. The connection calls it once the path is known to lie within
    /// the session's working directory, and before the file itself is examined; throw
    /// to refuse (a ``FileSystemPermissionError`` reaches the agent in acpx's words).
    /// `nil` approves every write.
    public var authorizeWrite: (@Sendable (WriteTextFileRequest) async throws -> Void)?
    /// Authorize an `fs/read_text_file` before the file is read — acpx refuses reads
    /// under `--deny-all`. Called at the same point as ``authorizeWrite``; throw to
    /// refuse. `nil` approves every read.
    public var authorizeRead: (@Sendable (ReadTextFileRequest) async throws -> Void)?

    public init(
        requestPermission: (@Sendable (RequestPermissionRequest) async throws -> RequestPermissionResponse)? = nil,
        readTextFile: (@Sendable (ReadTextFileRequest) async throws -> ReadTextFileResponse)? = nil,
        writeTextFile: (@Sendable (WriteTextFileRequest) async throws -> WriteTextFileResponse)? = nil,
        authorizeWrite: (@Sendable (WriteTextFileRequest) async throws -> Void)? = nil,
        authorizeRead: (@Sendable (ReadTextFileRequest) async throws -> Void)? = nil
    ) {
        self.requestPermission = requestPermission
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.authorizeWrite = authorizeWrite
        self.authorizeRead = authorizeRead
    }

    /// Sensible defaults for a headless controller: a permission policy plus real
    /// local file access (matching the `fs` capability we advertise), with writes
    /// gated the way acpx gates them — see ``WriteApproval``.
    ///
    /// - Parameters:
    ///   - nonInteractivePermissions: what a write needing confirmation does when
    ///     there is no terminal to ask on.
    ///   - confirmWrite: how to ask. `nil` asks on `terminal`, as acpx does.
    ///   - terminal: the terminal the default confirmation asks on.
    ///   - rules: a per-tool permission policy that comes before the mode `permission`
    ///     names — see ``PermissionRules``. A ``PermissionPolicy/custom(_:)`` resolver
    ///     answers without it, as acpx's host permission handler does.
    public static func standard(
        permission: PermissionPolicy,
        nonInteractivePermissions: NonInteractivePermissionPolicy = .deny,
        confirmWrite: WriteApproval.Confirmation? = nil,
        terminal: TerminalPermissionPrompt = .shared,
        rules: PermissionRules? = nil
    ) -> ACPClientHandlers {
        let approval = WriteApproval(
            policy: permission, nonInteractive: nonInteractivePermissions, confirm: confirmWrite,
            terminal: terminal)
        let tools = ToolPermissionApproval(
            policy: permission, nonInteractive: nonInteractivePermissions, rules: rules, terminal: terminal)
        return ACPClientHandlers(
            requestPermission: { try await tools.resolve($0) },
            readTextFile: { try LocalFileSystem.read($0) },
            writeTextFile: { try LocalFileSystem.write($0) },
            authorizeWrite: { try await approval.authorize($0) },
            authorizeRead: { _ in
                // acpx's `readTextFile`: only `--deny-all` refuses a read.
                if case .denyAll = permission { throw FileSystemPermissionError.readDenied }
            })
    }
}

// MARK: - Permission policy

/// How tool-call permission requests are answered when there is no interactive
/// user — or how an interactive front-end is wired in via `.custom`.
public enum PermissionPolicy: Sendable {
    /// Approve every request (selects an allow option).
    case approveAll
    /// Approve read/search tools; reject anything that can mutate or execute.
    case approveReads
    /// Reject every request.
    case denyAll
    /// Delegate to a custom resolver (e.g. an interactive prompt).
    case custom(@Sendable (RequestPermissionRequest) async -> RequestPermissionResponse)

    /// The policy for one of acpx's permission modes — `approve-all`, `approve-reads`,
    /// `deny-all` — or `nil` for anything else.
    public init?(acpxMode mode: String) {
        switch mode {
        case "approve-all": self = .approveAll
        case "approve-reads": self = .approveReads
        case "deny-all": self = .denyAll
        default: return nil
        }
    }

    /// Answer `request` the way ``ToolPermissionApproval`` does with no terminal to
    /// ask on and the default ``NonInteractivePermissionPolicy/deny``: what would be
    /// asked is refused.
    public func resolve(_ request: RequestPermissionRequest) async -> RequestPermissionResponse {
        (try? await ToolPermissionApproval(policy: self, nonInteractive: .deny, terminal: .none).resolve(request))
            ?? .cancelled
    }

    /// Select an allow option (preferring "once"), falling back to the first
    /// option, or cancel if none are offered.
    public static func approve(_ request: RequestPermissionRequest) -> RequestPermissionResponse {
        if let option = pick(request.options, [.allowOnce, .allowAlways]) ?? request.options.first {
            return .selected(option.optionId)
        }
        return .cancelled
    }

    /// Select a reject option (preferring "once"), or cancel if none are offered.
    /// Purely kind-based: which `reject_once` wins is the request's order, which is
    /// why the connection ranks Codex's non-aborting refusal first beforehand (see
    /// ``CodexCompat``).
    public static func reject(_ request: RequestPermissionRequest) -> RequestPermissionResponse {
        if let option = pick(request.options, [.rejectOnce, .rejectAlways]) {
            return .selected(option.optionId)
        }
        return .cancelled
    }

    public static func pick(_ options: [PermissionOption], _ kinds: [PermissionOptionKind]) -> PermissionOption? {
        for kind in kinds {
            if let match = options.first(where: { $0.kind == kind }) { return match }
        }
        return nil
    }
}

// MARK: - Local file system

/// The default implementation of the `fs/*` client methods: real reads/writes
/// against the local disk, honouring the optional `line`/`limit` window.
public enum LocalFileSystem {
    public static func read(_ request: ReadTextFileRequest) throws -> ReadTextFileResponse {
        let contents = try contents(ofFileAt: request.path)
        guard request.line != nil || request.limit != nil else {
            return ReadTextFileResponse(content: contents)
        }
        var lines = contents.components(separatedBy: "\n")
        // `line` is 1-based; clamp into range.
        if let line = request.line {
            let start = max(0, line - 1)
            lines = start < lines.count ? Array(lines[start...]) : []
        }
        if let limit = request.limit, limit >= 0, limit < lines.count {
            lines = Array(lines.prefix(limit))
        }
        return ReadTextFileResponse(content: lines.joined(separator: "\n"))
    }

    /// acpx's write: missing parent directories are created, an existing file is
    /// truncated and rewritten in place, and a new one is created `0666` (less the
    /// umask) — the mode fs-safe's `openWritable` asks for.
    public static func write(_ request: WriteTextFileRequest) throws -> WriteTextFileResponse {
        try write(request.content, toFileAt: request.path)
        return WriteTextFileResponse()
    }

    #if os(Windows)
    // Windows has no `O_NOFOLLOW`, and acpx's `fs-safe` disables it there for the same
    // reason (`resolveReadOpenFlags`: `process.platform !== "win32"`). Containment still
    // applies; the open simply cannot add the no-follow guarantee.
    private static func contents(ofFileAt path: String) throws -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            throw FileSystemContainment.resourceNotFound(path)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FileSystemContainment.refused(FileSystemContainment.notAFile)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func write(_ text: String, toFileAt path: String) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: break
            case .typeDirectory?: throw FileSystemContainment.refused(FileSystemContainment.notAFile)
            default:
                throw FileSystemContainment.refused(FileSystemContainment.notARegularFileUnderRoot)
            }
            if let links = attributes[.referenceCount] as? Int, links > 1 {
                throw FileSystemContainment.refused(FileSystemContainment.aliasEscapeBlocked)
            }
        } else {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
        }
        // A rename-into-place never writes through a second link.
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    #else
    /// acpx's `fs-safe` opens `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`; the final component
    /// must be the file itself, so an object swapped in after containment resolved the
    /// path fails the open instead of redirecting it. `O_NONBLOCK` keeps a reader-less
    /// fifo from hanging, and the type is decided on the descriptor.
    private static func contents(ofFileAt path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw FileSystemContainment.resourceNotFound(path)
            case ELOOP: throw FileSystemContainment.refused(FileSystemContainment.outsideWorkspaceRoot)
            default: throw FileSystemContainment.refused(String(cString: strerror(errno)))
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fileType(of: descriptor) == UInt32(S_IFREG) else {
            throw FileSystemContainment.refused(FileSystemContainment.notAFile)
        }
        let data = try handle.readToEnd() ?? Data()
        guard let contents = String(data: data, encoding: .utf8) else {
            throw FileSystemContainment.refused("Not UTF-8 text: \(path)")
        }
        return contents
    }

    /// Checked before the open so the common refusals need no descriptor, and again on
    /// the descriptor so a swap in between cannot win: truncation waits until the open
    /// file is known to be a regular file with one link. Truncating at open (`O_TRUNC`)
    /// would already have emptied a hard link swapped in after the first check.
    ///
    /// `O_NONBLOCK` is what keeps a fifo from hanging the client: without it, opening a
    /// fifo for writing blocks until a reader turns up, which never happens.
    private static func write(_ text: String, toFileAt path: String) throws {
        var status = stat()
        if lstat(path, &status) == 0 {
            try requireWritableRegularFile(status)
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, mode_t(0o666))
        guard descriptor >= 0 else {
            switch errno {
            case ENXIO: throw FileSystemContainment.refused(FileSystemContainment.notARegularFileUnderRoot)
            case EISDIR: throw FileSystemContainment.refused(FileSystemContainment.notAFile)
            case ELOOP: throw FileSystemContainment.refused(FileSystemContainment.outsideWorkspaceRoot)
            default: throw FileSystemContainment.refused(String(cString: strerror(errno)))
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(descriptor, &status) == 0 else {
            throw FileSystemContainment.refused(String(cString: strerror(errno)))
        }
        try requireWritableRegularFile(status)
        guard ftruncate(descriptor, 0) == 0 else {
            throw FileSystemContainment.refused(String(cString: strerror(errno)))
        }
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// fs-safe's refusals for a write target, in its words: a directory is "not a file",
    /// anything else that is not a regular file (a fifo, a socket, a device) is "not a
    /// regular file under root", and a regular file with a second link is refused
    /// because that link may lie outside the workspace — writing through it would
    /// change a file the agent was never given.
    private static func requireWritableRegularFile(_ status: stat) throws {
        switch UInt32(status.st_mode) & UInt32(S_IFMT) {
        case UInt32(S_IFREG): break
        case UInt32(S_IFDIR): throw FileSystemContainment.refused(FileSystemContainment.notAFile)
        case UInt32(S_IFLNK): throw FileSystemContainment.refused(FileSystemContainment.outsideWorkspaceRoot)
        default: throw FileSystemContainment.refused(FileSystemContainment.notARegularFileUnderRoot)
        }
        guard status.st_nlink <= 1 else {
            throw FileSystemContainment.refused(FileSystemContainment.aliasEscapeBlocked)
        }
    }

    /// The file-type bits of an open descriptor. `st_mode` is `UInt16` on Darwin and
    /// `UInt32` on Linux, so both sides are widened before masking.
    private static func fileType(of descriptor: Int32) -> UInt32? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return UInt32(status.st_mode) & UInt32(S_IFMT)
    }
    #endif
}
