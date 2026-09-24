import Foundation

/// Serves the ACP `terminal/*` methods for a connection — the part of acpx's
/// `TerminalManager` that runs commands.
///
/// A connection holds one for as long as it lives (see
/// ``ACPAgentConnection/setTerminalHandler(_:)``): a terminal outlives the turn that
/// created it, as an agent's background shell does, and every one still open is
/// released when the connection ends. Whether a command may run at all is the turn's
/// decision: the connection asks ``ACPClientHandlers/authorizeTerminal`` before
/// ``createTerminal(_:)``.
///
/// Throw a ``TerminalError`` to refuse a request in acpx's words; any error reaches the
/// agent as `Internal error`, with its message in `data.details`.
public protocol ACPTerminalHandler: AnyObject, Sendable {
    func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse
    func terminalOutput(_ request: TerminalOutputRequest) async throws -> TerminalOutputResponse
    func waitForTerminalExit(_ request: WaitForTerminalExitRequest) async throws
        -> WaitForTerminalExitResponse
    func killTerminal(_ request: KillTerminalRequest) async throws -> KillTerminalResponse
    func releaseTerminal(_ request: ReleaseTerminalRequest) async throws -> ReleaseTerminalResponse
    /// Release every terminal still open: the connection has ended. A
    /// ``createTerminal(_:)`` arriving once this has begun must be refused (throw
    /// `CancellationError`), or its command would outlive the connection.
    func shutdown() async
}

/// Why a `terminal/*` request failed. The messages are acpx's, and reach the agent in
/// `data.details`.
public enum TerminalError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// A `terminal/create` refused by the permission mode, or by the user at the prompt.
    case permissionDenied
    /// No terminal has this id: it was never created, or it was released.
    case unknownTerminal(String)
    /// The command could not be started — Node's `spawn <command> <code>`, where the
    /// code is the errno's name, such as `ENOENT`.
    case spawnFailed(command: String, code: String)
    /// A value `spawn` refuses before starting anything — an empty command, or a NUL
    /// inside the command, an argument, the directory or a variable, which C would cut
    /// short — in Node's `ERR_INVALID_ARG_VALUE` words.
    case invalidSpawnArgument(String)

    public var description: String {
        switch self {
        case .permissionDenied: return "Permission denied for terminal/create"
        case .unknownTerminal(let id): return "Unknown terminal: \(id)"
        case .spawnFailed(let command, let code): return "spawn \(command) \(code)"
        case .invalidSpawnArgument(let message): return message
        }
    }

    public var errorDescription: String? { description }
}

/// Whether an agent may run a command — acpx's `TerminalManager.isExecuteApproved`.
///
/// Like a file write, a `terminal/create` carries no `session/request_permission` to
/// answer, so the client asks on its own. Upstream, and so here:
///
/// | mode | outcome |
/// |---|---|
/// | ``PermissionPolicy/approveAll`` | run |
/// | ``PermissionPolicy/denyAll`` | refused — ``TerminalError/permissionDenied`` |
/// | anything else | asked — see ``Confirmation`` |
///
/// The default ``Confirmation`` asks `[permission] Allow terminal command "…"? (y/N)` on
/// the terminal, and answers *no* when there is none; with
/// ``NonInteractivePermissionPolicy/fail`` the command is refused as unanswerable
/// instead (``PermissionPromptUnavailableError``) — but only for that default prompt: an
/// embedder that supplies its own confirmation is trusted to answer headless.
public struct TerminalApproval: Sendable {
    /// Ask whether to allow running `commandLine` (see ``commandLine(command:args:)``).
    /// Return `false` to refuse.
    public typealias Confirmation = @Sendable (_ commandLine: String) async throws -> Bool

    public let policy: PermissionPolicy
    public let nonInteractive: NonInteractivePermissionPolicy
    private let confirm: Confirmation
    private let usesDefaultConfirmation: Bool
    private let prompt: TerminalPermissionPrompt

    /// - Parameter terminal: where the default confirmation asks — the process's own
    ///   terminal unless told otherwise. ``TerminalPermissionPrompt/none`` never asks.
    public init(
        policy: PermissionPolicy,
        nonInteractive: NonInteractivePermissionPolicy = .deny,
        confirm: Confirmation? = nil,
        terminal: TerminalPermissionPrompt = .shared
    ) {
        self.policy = policy
        self.nonInteractive = nonInteractive
        self.prompt = terminal
        self.confirm = confirm ?? { commandLine in
            try await terminal.ask(prompt: "\n[permission] Allow terminal command \"\(commandLine)\"? (y/N) ")
        }
        usesDefaultConfirmation = confirm == nil
    }

    /// Allow the command, or throw ``TerminalError/permissionDenied`` or
    /// ``PermissionPromptUnavailableError``.
    public func authorize(_ request: CreateTerminalRequest) async throws {
        switch policy {
        case .approveAll:
            return
        case .denyAll:
            throw TerminalError.permissionDenied
        case .approveReads, .custom:
            if usesDefaultConfirmation, nonInteractive == .fail, !prompt.canPrompt {
                throw PermissionPromptUnavailableError()
            }
            guard try await confirm(Self.commandLine(command: request.command, args: request.args)) else {
                throw TerminalError.permissionDenied
            }
        }
    }

    /// acpx's `toCommandLine`: the command, then each argument quoted as
    /// `JSON.stringify` quotes a string — what the confirmation shows.
    public static func commandLine(command: String, args: [String]?) -> String {
        let quoted = (args ?? []).map(javaScriptQuoted).joined(separator: " ")
        return quoted.isEmpty ? command : "\(command) \(quoted)"
    }

    /// `JSON.stringify` of a string: the short escapes, `\u00XX` (lowercase hex) for
    /// the other control characters, and everything else as itself.
    static func javaScriptQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{00}"..."\u{1F}":
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

// MARK: - Output limits

/// How much of a command's output a terminal keeps — acpx's
/// `resolveTerminalOutputLimit` and its host ceiling.
public enum TerminalOutputLimit {
    /// acpx's `DEFAULT_TERMINAL_OUTPUT_LIMIT_BYTES`: what a request naming no limit gets.
    public static let defaultBytes = 64 * 1024

    /// The largest integer JavaScript represents exactly — acpx's `Number.isSafeInteger`.
    static let maxSafeInteger = 9_007_199_254_740_991

    /// acpx's `readTerminalOutputCeiling`: `ACPX_TERMINAL_MAX_OUTPUT_BYTES`, trimmed. Unset,
    /// empty and `0` are no ceiling; anything but decimal digits naming a safe integer
    /// is refused with ``TerminalOutputCeilingError``, as acpx refuses to start.
    public static func ceiling(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int? {
        guard let raw = environment["ACPX_TERMINAL_MAX_OUTPUT_BYTES"] else { return nil }
        let trimmed = javaScriptTrimmed(raw)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
            throw TerminalOutputCeilingError()
        }
        let digits = trimmed.drop { $0 == "0" }
        guard digits.count <= 16, let bytes = Int(digits.isEmpty ? "0" : String(digits)),
            bytes <= maxSafeInteger
        else { throw TerminalOutputCeilingError() }
        return bytes == 0 ? nil : bytes
    }

    /// A ceiling given as a count rather than read from the environment — `0` is none —
    /// held to the same rule: a negative or unsafe count is refused with
    /// ``TerminalOutputCeilingError``.
    public static func ceiling(bytes: Int) throws -> Int? {
        guard bytes >= 0, bytes <= maxSafeInteger else { throw TerminalOutputCeilingError() }
        return bytes == 0 ? nil : bytes
    }

    /// The bytes a terminal keeps: the request's limit (``defaultBytes`` without one),
    /// at least 0, at most the ceiling.
    public static func resolve(requested: Int?, ceiling: Int?) -> Int {
        min(max(0, requested ?? defaultBytes), ceiling ?? Int.max)
    }

    /// JavaScript's `trim()`.
    static func javaScriptTrimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isJavaScriptWhitespace($0) }),
            let last = scalars.lastIndex(where: { !isJavaScriptWhitespace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    /// JavaScript's `WhiteSpace` and `LineTerminator` — what `trim()` and `\s` match.
    static func isJavaScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029: return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }
}

/// `ACPX_TERMINAL_MAX_OUTPUT_BYTES` is not a non-negative safe integer. acpx will not
/// start a client under it; the message is its own.
public struct TerminalOutputCeilingError: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "ACPX_TERMINAL_MAX_OUTPUT_BYTES must be a non-negative safe integer; zero disables the host ceiling"
    }

    public var errorDescription: String? { description }
}

/// A terminal's retained output: stdout and stderr together, in the order they were
/// read, cut to the newest `limit` bytes. Once anything has been cut, the kept bytes
/// always start on a character boundary, since a later chunk can finish a character
/// whose first bytes are already gone.
final class TerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var truncated = false
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            bytes += chunk
            truncated = truncated || bytes.count > limit
            if truncated { bytes = Self.suffix(bytes, limit: limit) }
        }
    }

    /// The output as text — invalid UTF-8 replaced, as Node's `toString("utf8")` does —
    /// and whether bytes were dropped.
    func read() -> (text: String, truncated: Bool) {
        lock.withLock { (String(decoding: bytes, as: UTF8.self), truncated) }
    }

    func clear() {
        lock.withLock { bytes = [] }
    }

    /// acpx's `trimToUtf8Boundary`: the last `limit` bytes, less any continuation bytes
    /// they start with.
    static func suffix(_ bytes: [UInt8], limit: Int) -> [UInt8] {
        guard limit > 0 else { return [] }
        var start = max(0, bytes.count - limit)
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 {
            start += 1
        }
        return Array(bytes[start...])
    }
}
