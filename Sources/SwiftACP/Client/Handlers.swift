import Foundation
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
    /// explains a refusal that may end the turn on the way back.
    public var requestPermission:
        (@Sendable (RequestPermissionRequest) async -> RequestPermissionResponse)?
    /// Serve `fs/read_text_file`: return file content, honouring `line`/`limit`.
    public var readTextFile: (@Sendable (ReadTextFileRequest) async throws -> ReadTextFileResponse)?
    /// Serve `fs/write_text_file`: write the given content to the given path.
    public var writeTextFile:
        (@Sendable (WriteTextFileRequest) async throws -> WriteTextFileResponse)?

    public init(
        requestPermission: (@Sendable (RequestPermissionRequest) async -> RequestPermissionResponse)? = nil,
        readTextFile: (@Sendable (ReadTextFileRequest) async throws -> ReadTextFileResponse)? = nil,
        writeTextFile: (@Sendable (WriteTextFileRequest) async throws -> WriteTextFileResponse)? = nil
    ) {
        self.requestPermission = requestPermission
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }

    /// Sensible defaults for a headless controller: a permission policy plus
    /// real local file access (matching the `fs` capability we advertise).
    public static func standard(permission: PermissionPolicy) -> ACPClientHandlers {
        ACPClientHandlers(
            requestPermission: { await permission.resolve($0) },
            readTextFile: { try LocalFileSystem.read($0) },
            writeTextFile: { try LocalFileSystem.write($0) })
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

    /// Tool kinds considered safe to auto-approve under `.approveReads`.
    private static let safeKinds: Set<ToolKind> = [.read, .search]

    public func resolve(_ request: RequestPermissionRequest) async -> RequestPermissionResponse {
        switch self {
        case .custom(let resolver):
            return await resolver(request)
        case .approveAll:
            return Self.approve(request)
        case .denyAll:
            return Self.reject(request)
        case .approveReads:
            if let kind = request.toolCall.kind, Self.safeKinds.contains(kind) {
                return Self.approve(request)
            }
            return Self.reject(request)
        }
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
    /// `O_NOFOLLOW` where the platform has it, as acpx's `fs-safe` does
    /// (`resolveReadOpenFlags`: `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, disabled on
    /// Windows). The final component must be the file itself, not a link to one — a
    /// symlink swapped in after the path was validated fails the open instead of
    /// redirecting the read.
    private static var noFollow: Int32 {
        #if os(Windows)
        return 0
        #else
        return O_NOFOLLOW | O_NONBLOCK
        #endif
    }

    public static func read(_ request: ReadTextFileRequest) throws -> ReadTextFileResponse {
        let descriptor = open(request.path, O_RDONLY | noFollow)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw FileSystemContainment.resourceNotFound(request.path)
            case ELOOP: throw FileSystemContainment.symlinkRefused(request.path)
            default:
                throw JSONRPCError.invalidParams(
                    "Cannot read \(request.path): \(String(cString: strerror(errno)))")
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // The type check belongs on the descriptor: a path stat'd first could be a
        // different object by the time it is opened.
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw FileSystemContainment.notARegularFile(request.path)
        }
        let data = try handle.readToEnd() ?? Data()
        guard let contents = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.invalidParams("Not UTF-8 text: \(request.path)")
        }
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

    public static func write(_ request: WriteTextFileRequest) throws -> WriteTextFileResponse {
        let url = URL(fileURLWithPath: request.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Same reasoning as `read`: the final component is opened no-follow, so a
        // symlink planted after the path was contained cannot redirect the write.
        let descriptor = open(request.path, O_WRONLY | O_CREAT | O_TRUNC | noFollow, 0o644)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw FileSystemContainment.symlinkRefused(request.path) }
            throw JSONRPCError.invalidParams(
                "Cannot write \(request.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw FileSystemContainment.notARegularFile(request.path)
        }
        try handle.write(contentsOf: Data(request.content.utf8))
        return WriteTextFileResponse()
    }
}
