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

    public static func write(_ request: WriteTextFileRequest) throws -> WriteTextFileResponse {
        let url = URL(fileURLWithPath: request.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            throw FileSystemContainment.notARegularFile(path)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func write(_ text: String, toFileAt path: String) throws {
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
            case ENOENT: throw FileSystemContainment.resourceNotFound(path)
            case ELOOP: throw FileSystemContainment.symlinkRefused(path)
            default:
                throw JSONRPCError.invalidParams(
                    "Cannot read \(path): \(String(cString: strerror(errno)))")
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try requireRegularFile(descriptor, path)
        let data = try handle.readToEnd() ?? Data()
        guard let contents = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.invalidParams("Not UTF-8 text: \(path)")
        }
        return contents
    }

    private static func write(_ text: String, toFileAt path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(0o644))
        guard descriptor >= 0 else {
            if errno == ELOOP { throw FileSystemContainment.symlinkRefused(path) }
            throw JSONRPCError.invalidParams(
                "Cannot write \(path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try requireRegularFile(descriptor, path)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Checked on the descriptor, not the path: `st_mode` is `UInt16` on Darwin and
    /// `UInt32` on Linux, so both sides are widened before masking.
    private static func requireRegularFile(_ descriptor: Int32, _ path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            UInt32(status.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG)
        else { throw FileSystemContainment.notARegularFile(path) }
    }
    #endif
}
