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
    struct Plan {
        var clientInfo: Implementation
        var capabilities: ClientCapabilities
        private let copilot: Bool
        private let command: String
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
                self.capabilities.meta = devinCapabilitiesMeta
            }
            copilot = isCopilot(spec.executable, spec.arguments)
            command = spec.executable
            self.probe = probe
        }

        /// acpx's `ensureLaunchSupport`: Copilot's CLI must have an ACP mode.
        func ensureSupported() async throws {
            if copilot { try await ensureCopilotSupport(command, probe: probe) }
        }
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
