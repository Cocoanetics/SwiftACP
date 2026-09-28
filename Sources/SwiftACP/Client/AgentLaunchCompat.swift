import Foundation
import JSONFoundation

/// How acpx's client adapts an agent's launch to the agent (`src/acp/agent-command.ts`,
/// `src/acp/client-protocol.ts`, acpx 0.19.3): by the base name of the command that starts it
/// and by its arguments, however the agent was named (#248).
enum AgentLaunchCompat {
    /// Runs a helper command the way the agent will run — its directory, its environment — and
    /// gives what it wrote, or `nil` (``CommandProbe``).
    typealias Probe = @Sendable (_ command: String, _ arguments: [String], _ timeoutMilliseconds: Int) async -> String?

    // MARK: Which agent

    /// acpx's `isGeminiAcpCommand`.
    static func isGemini(_ command: String, _ arguments: [String]) -> Bool {
        token(command) == "gemini" && (arguments.contains("--acp") || arguments.contains("--experimental-acp"))
    }

    /// acpx's `isCopilotAcpCommand`.
    static func isCopilot(_ command: String, _ arguments: [String]) -> Bool {
        token(command) == "copilot" && arguments.contains("--acp")
    }

    /// acpx's `isQoderAcpCommand`.
    static func isQoder(_ command: String, _ arguments: [String]) -> Bool {
        token(command) == "qodercli" && arguments.contains("--acp")
    }

    /// acpx's `isClaudeAcpCommand`: Claude's adapter, run directly or through a package runner.
    static func isClaude(_ command: String, _ arguments: [String]) -> Bool {
        token(command) == "claude-agent-acp" || arguments.contains { $0.contains("claude-agent-acp") }
    }

    /// acpx's `isDevinAcpCommand`.
    static func isDevin(_ command: String, _ arguments: [String]) -> Bool {
        token(command) == "devin"
            && (arguments.contains("acp") || arguments.contains("--acp") || arguments.contains("--experimental-acp"))
    }

    private static func token(_ command: String) -> String { AgentCommandQuirks.basenameToken(command) }

    // MARK: The launch

    /// An agent's launch as acpx adapts it (`resolveAgentLaunchPlan`, `ensureLaunchSupport`,
    /// `initializeProtocolConnection`): what it says of itself as it initializes, and the check
    /// it passes before it is spawned.
    struct Plan: Sendable {
        var clientInfo: Implementation
        var capabilities: ClientCapabilities
        /// How long Gemini's `initialize` may take, in milliseconds; none for any other agent.
        let initializeLimit: Int?
        /// How long Claude's adapter may take to answer `session/new`; none for any other agent.
        let sessionCreateLimit: Int?
        private let copilot: Bool
        private let claude: Bool
        private let command: String
        private let agentEnvironment: [String: String]
        private let probe: Probe

        /// `spec`'s arguments adapted — Gemini's ACP flag, Qoder's session limits — and Devin
        /// initialized as the Windsurf client it answers, `ACPX_DEVIN_WINDSURF_VERSION` read from
        /// `callerEnvironment`, the client's own.
        init(
            _ spec: inout ProcessLaunch, limits: SessionLimits?, clientInfo: Implementation,
            capabilities: ClientCapabilities, callerEnvironment: [String: String], probe: @escaping Probe
        ) async {
            spec.arguments = await geminiArguments(spec.executable, spec.arguments, probe: probe)
            if isQoder(spec.executable, spec.arguments) {
                spec.arguments = qoderArguments(
                    spec.arguments, maxTurns: limits?.maxTurns, allowedTools: limits?.allowedTools)
            }
            self.clientInfo = clientInfo
            self.capabilities = capabilities
            if isDevin(spec.executable, spec.arguments) {
                self.clientInfo = devinClientInfo(environment: callerEnvironment)
                self.capabilities.meta = devinMeta(merging: capabilities.meta)
            }
            copilot = isCopilot(spec.executable, spec.arguments)
            claude = isClaude(spec.executable, spec.arguments)
            initializeLimit = isGemini(spec.executable, spec.arguments)
                ? startupMilliseconds(callerEnvironment["ACPX_GEMINI_ACP_STARTUP_TIMEOUT_MS"], fallback: 15_000) : nil
            sessionCreateLimit = isClaude(spec.executable, spec.arguments)
                ? startupMilliseconds(callerEnvironment["ACPX_CLAUDE_ACP_SESSION_CREATE_TIMEOUT_MS"], fallback: 60_000)
                : nil
            command = spec.executable
            agentEnvironment = spec.environment ?? ProcessInfo.processInfo.environment
            self.probe = probe
        }

        /// `operation` — the agent's `initialize` — within Gemini's limit, as acpx's
        /// `initializeProtocolConnection` caps it; past it, ``StartupTimedOut``.
        func initializing<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            guard let initializeLimit else { return try await operation() }
            return try await within(initializeLimit, operation)
        }

        /// What a Gemini that did not get through `initialize` in time fails with, once it is
        /// gone (acpx's `handleInitializeFailure`); `nil` for any other failure.
        func startupFailure(_ error: Error) async -> Error? {
            guard initializeLimit != nil, error is StartupTimedOut else { return nil }
            return GeminiAcpStartupTimeoutError(
                message: await geminiStartupTimeoutMessage(command, agentEnvironment: agentEnvironment, probe: probe))
        }

        /// acpx's `ensureLaunchSupport`: Copilot's CLI must have an ACP mode.
        func ensureSupported() async throws {
            if copilot { try await ensureCopilotSupport(command, probe: probe) }
        }

        /// The rest of acpx's `ensureLaunchSupport`: on Windows, the Claude Code program for Claude's
        /// adapter to run (`resolveClaudeCodeExecutable`), unless its environment names one; `nil`
        /// for any other agent, or elsewhere (#272).
        func claudeCodeExecutable(cwd: String) -> String? {
            #if os(Windows)
            guard claude else { return nil }
            return WindowsSpawnCommand.claudeCodeExecutable(
                environment: agentEnvironment, cwd: cwd, fileSystem: .local,
                processDirectory: FileManager.default.currentDirectoryPath)
            #else
            return nil
            #endif
        }
    }

    // MARK: Startup limits

    /// A limit acpx's `withTimeout` reached before what it waited for came.
    struct StartupTimedOut: Error {
        let milliseconds: Int
    }

    /// The limit acpx's `resolveGeminiAcpStartupTimeoutMs` and `resolveClaudeAcpSessionCreateTimeoutMs`
    /// read from `raw`, as `withTimeout` then sets it: `fallback` unless `Number` reads a positive,
    /// finite number; `Math.round` of it; none when that is 0 (`withTimeout` waits without one);
    /// 1 ms past Node's timer maximum, as `setTimeout` takes it.
    static func startupMilliseconds(_ raw: String?, fallback: Int) -> Int? {
        guard let raw else { return fallback }
        let parsed = JavaScriptNumber.parse(raw)
        guard parsed.isFinite, parsed > 0 else { return fallback }
        let rounded = (parsed + 0.5).rounded(.down)
        guard rounded > 0 else { return nil }
        return rounded > Double(JavaScriptNumber.maxTimerDelayMs) ? 1 : Int(rounded)
    }

    /// `operation`'s result, or ``StartupTimedOut`` once `milliseconds` pass first — acpx's
    /// `withTimeout`, its timer firing on a queue of its own, and put away with what it holds as
    /// soon as there is an outcome. Like a promise, the operation goes on; what it waits for ends
    /// with the agent. A caller called off stops waiting at once, as `withTimeout`'s does (#267 review).
    static func within<T: Sendable>(
        _ milliseconds: Int, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let first = FirstOutcome<T>()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(milliseconds))
        timer.setEventHandler { [weak first] in first?.settle(.failure(StartupTimedOut(milliseconds: milliseconds))) }
        // The caller holds the outcome while it waits; the timer, cancelled with it, holds nothing.
        defer { timer.cancel() }
        let task = Task {
            do {
                first.settle(.success(try await operation()))
            } catch {
                first.settle(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                first.wait(continuation)
                timer.resume()
            }
        } onCancel: {
            first.settle(.failure(CancellationError()))
            task.cancel()
        }
    }

    /// acpx's `buildGeminiAcpStartupTimeoutMessage`: what Gemini's version and the agent's
    /// environment say of why it stalled.
    static func geminiStartupTimeoutMessage(
        _ command: String, agentEnvironment: [String: String], probe: Probe
    ) async -> String {
        var parts = [
            "Gemini CLI ACP startup timed out before initialize completed.",
            "This usually means the local Gemini CLI is waiting on interactive OAuth or has incompatible "
                + "ACP subprocess behavior."
        ]
        if let version = geminiVersion(in: await probe(command, ["--version"], 2_000)) {
            parts.append("Detected Gemini CLI version: \(version.raw).")
        }
        if (agentEnvironment["GEMINI_API_KEY"] ?? "").isEmpty, (agentEnvironment["GOOGLE_API_KEY"] ?? "").isEmpty {
            parts.append("No GEMINI_API_KEY or GOOGLE_API_KEY was set for non-interactive auth.")
        }
        parts.append("Try upgrading Gemini CLI and using API-key-based auth for non-interactive ACP runs.")
        return parts.joined(separator: " ")
    }

    // MARK: Gemini

    /// The first version Gemini CLI takes `--acp` in; before it, `--experimental-acp`.
    static let geminiAcpFlagVersion: [Double] = [0, 33, 0]

    /// acpx's `resolveGeminiCommandArgs`: `gemini --acp` asks `gemini --version` first, and a
    /// version before 0.33.0 gets `--experimental-acp` in its place.
    static func geminiArguments(_ command: String, _ arguments: [String], probe: Probe) async -> [String] {
        guard token(command) == "gemini", arguments.contains("--acp") else { return arguments }
        guard let version = geminiVersion(in: await probe(command, ["--version"], 2_000)),
              compare(version.parts, geminiAcpFlagVersion) < 0
        else { return arguments }
        return arguments.map { $0 == "--acp" ? "--experimental-acp" : $0 }
    }

    /// A Gemini CLI version as `gemini --version` gave it: the line it is on, trimmed, and its
    /// three numbers.
    struct Version: Equatable {
        let raw: String
        let parts: [Double]
    }

    /// acpx's `detectGeminiVersion`: the first line of `output` with a `<n>.<n>.<n>` in it,
    /// trimmed, and the first such numbers on it.
    static func geminiVersion(in output: String?) -> Version? {
        guard let output else { return nil }
        // `/\r?\n/`: a `\r` before a line's end goes with the trimming.
        for line in Array(output.utf16).split(separator: 0x0A, omittingEmptySubsequences: false) {
            let trimmed = String(decoding: javaScriptTrimmed(Array(line)), as: UTF16.self)
            if let parts = firstVersion(in: Array(trimmed.utf16)) { return Version(raw: trimmed, parts: parts) }
        }
        return nil
    }

    /// The numbers of the leftmost `(\d+)\.(\d+)\.(\d+)` in `units`, JavaScript's `\d` being the
    /// ASCII digits.
    private static func firstVersion(in units: [UInt16]) -> [Double]? {
        func digits(from index: Int) -> Int {
            var end = index
            while end < units.count, (0x30...0x39).contains(units[end]) { end += 1 }
            return end
        }
        for start in units.indices where (0x30...0x39).contains(units[start]) {
            var parts: [Double] = []
            var index = start
            for part in 0..<3 {
                let end = digits(from: index)
                guard end > index else { break }
                parts.append(Double(String(decoding: units[index..<end], as: UTF16.self)) ?? 0)
                index = end
                if part < 2 {
                    guard index < units.count, units[index] == 0x2E else { break }
                    index += 1
                }
            }
            if parts.count == 3 { return parts }
        }
        return nil
    }

    /// acpx's `compareVersionParts`.
    static func compare(_ left: [Double], _ right: [Double]) -> Double {
        for index in 0..<max(left.count, right.count) {
            let (lhs, rhs) = (index < left.count ? left[index] : 0, index < right.count ? right[index] : 0)
            if lhs != rhs { return lhs - rhs }
        }
        return 0
    }

    // MARK: Copilot

    /// acpx's `ensureCopilotAcpSupport`: `copilot --help` that says nothing of `--acp` means the
    /// CLI has no ACP mode; one that could not be asked is no reason not to try.
    static func ensureCopilotSupport(_ command: String, probe: Probe) async throws {
        guard let help = await probe(command, ["--help"], 2_000), !help.contains("--acp") else { return }
        throw CopilotAcpUnsupportedError()
    }

    // MARK: Qoder

    /// acpx's `buildQoderAcpCommandArgs`: the session's turn limit and allowed tools on Qoder's
    /// command line, unless it names them already.
    static func qoderArguments(_ arguments: [String], maxTurns: Int?, allowedTools: [String]?) -> [String] {
        var arguments = arguments
        if let maxTurns, !hasFlag(arguments, "--max-turns") { arguments.append("--max-turns=\(maxTurns)") }
        if let allowedTools, !hasFlag(arguments, "--allowed-tools"), !hasFlag(arguments, "--disallowed-tools") {
            arguments.append("--allowed-tools=" + allowedTools.map(qoderToolName).joined(separator: ","))
        }
        return arguments
    }

    /// acpx's `hasCommandFlag`.
    private static func hasFlag(_ arguments: [String], _ flag: String) -> Bool {
        arguments.contains { $0 == flag || $0.hasPrefix(flag + "=") }
    }

    /// acpx's `normalizeQoderAllowedToolName`: Qoder's own tools by their names in capitals.
    static func qoderToolName(_ tool: String) -> String {
        let trimmed = String(decoding: javaScriptTrimmed(Array(tool.utf16)), as: UTF16.self)
        switch trimmed.lowercased() {
        case "bash", "glob", "grep", "ls", "read", "write": return trimmed.uppercased()
        default: return trimmed
        }
    }

    // MARK: Devin

    /// What Devin's ACP server takes a client for (`resolveClientInfo`): Windsurf, at the
    /// version `ACPX_DEVIN_WINDSURF_VERSION` names, or the one bundled with Devin Desktop 3.1.7.
    static func devinClientInfo(environment: [String: String]) -> Implementation {
        Implementation(name: "windsurf", version: environment["ACPX_DEVIN_WINDSURF_VERSION"] ?? "1.110.1")
    }

    /// What a client says it answers for Devin (`resolveClientCapabilities`).
    static let devinCapabilitiesMeta: JSONValue = .object(["cognition.ai/requestDiagnostics": .bool(true)])

    /// The client's own `_meta`, when it is an object, with Devin's key set in it — acpx's
    /// client has none of its own to keep, but a caller's is theirs to say (#263 review).
    static func devinMeta(merging meta: JSONValue?) -> JSONValue {
        guard case .object(var members)? = meta else { return devinCapabilitiesMeta }
        members["cognition.ai/requestDiagnostics"] = .bool(true)
        return .object(members)
    }

    /// The request Devin asks a client that says it answers it; acpx answers `{}`.
    static let devinDiagnosticsMethod = "_cognition.ai/request_diagnostics"

    /// JavaScript's `String.prototype.trim` on UTF-16 code units.
    private static func javaScriptTrimmed(_ units: [UInt16]) -> [UInt16] {
        func isSpace(_ unit: UInt16) -> Bool {
            switch unit {
            case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                return true
            default: return false
            }
        }
        guard let first = units.firstIndex(where: { !isSpace($0) }),
              let last = units.lastIndex(where: { !isSpace($0) })
        else { return [] }
        return Array(units[first...last])
    }
}

/// What a session limits its agent to — its turns, its tools — which acpx puts on the command
/// line of an agent that takes them there (Qoder, `buildQoderAcpCommandArgs`), and otherwise
/// sends as the session's options.
public struct SessionLimits: Equatable, Sendable {
    public var maxTurns: Int?
    public var allowedTools: [String]?

    public init(maxTurns: Int? = nil, allowedTools: [String]? = nil) {
        self.maxTurns = maxTurns
        self.allowedTools = allowedTools
    }
}

/// The first of an operation's result and its limit, handed to whoever waits for it.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func settle(_ result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: result)
    }

    func wait(_ continuation: CheckedContinuation<T, Error>) {
        let settled: Result<T, Error>? = lock.withLock {
            if outcome == nil { waiter = continuation }
            return outcome
        }
        if let settled { continuation.resume(with: settled) }
    }
}

/// acpx's `GeminiAcpStartupTimeoutError`: Gemini's CLI did not get through `initialize` in time.
public struct GeminiAcpStartupTimeoutError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// acpx's `ClaudeAcpSessionCreateTimeoutError`: Claude's adapter did not answer `session/new` in time.
public struct ClaudeAcpSessionCreateTimeoutError: Error, LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Claude ACP session creation timed out before session/new completed. "
            + "This matches the known persistent-session stall seen with some Claude Code and "
            + "@agentclientprotocol/claude-agent-acp combinations. "
            + "In harnessed or non-interactive runs, prefer --approve-all with nonInteractivePermissions=deny, "
            + "upgrade Claude Code and the Claude ACP adapter, or use acpx claude exec as a one-shot fallback."
    }
}

/// acpx's `CopilotAcpUnsupportedError`: the installed `copilot` has no ACP stdio mode.
public struct CopilotAcpUnsupportedError: Error, LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        "GitHub Copilot CLI ACP stdio mode is not available in the installed copilot binary. "
            + "acpx copilot expects a Copilot CLI release that supports --acp --stdio. "
            + "Detected copilot --help output without --acp support. "
            + "Upgrade GitHub Copilot CLI to a release with ACP stdio support, "
            + "or use --agent with another ACP-compatible adapter in the meantime."
    }
}
