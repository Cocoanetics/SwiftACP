import Foundation
import JSONRPCWire

/// Known ACP agents and how to launch them.
///
/// Each entry is a shell-style command line for the agent's ACP adapter. The
/// built-in coding agents (Claude Code, Codex) ship as npm packages run through
/// `npx`; if their adapter binary is already on `PATH` we prefer it to avoid the
/// npx resolution step. Ported from acpx's `agent-registry.ts`.
public enum AgentRegistry {
    /// Pinned adapter package ranges, mirroring upstream acpx's
    /// `ACP_ADAPTER_PACKAGE_RANGES` (v0.19.1).
    ///
    /// `codex` used to be pinned ahead of acpx deliberately: at the 0.11.0 port
    /// baseline acpx still pinned `^0.0.44`, whose bundled `@openai/codex` (0.128.0)
    /// fails `initialize` with an opaque "Codex process has exited with code 1"
    /// because macOS XProtect (def 5347) quarantines that build as a false positive
    /// (issue #11 / openclaw/acpx#434). Upstream has since moved to `^1.1.5`, past
    /// the flagged build, so these simply track upstream again. The
    /// ``launch(for:cwd:environment:inheritStderr:overrides:)`` `CODEX_PATH` fallback
    /// covers a flagged bundle independently whenever a system `codex` is installed.
    public enum PackageRange {
        public static let claude = "^0.76.0"
        public static let codex = "^1.1.5"
        public static let mux = "^0.28.0"
        public static let pi = "^0.0.33"
    }

    /// agent name → launch command line, in registry declaration order — the
    /// same order acpx lists them under `Commands:` in `--help`. Swift's
    /// `Dictionary` is unordered, so the ordered array is the source of truth and
    /// ``builtIn`` is derived from it. Mirrors acpx's `AGENT_REGISTRY`.
    public static let ordered: [(name: String, command: String)] = [
        ("pi", "npx pi-acp@\(PackageRange.pi)"),
        ("openclaw", "openclaw acp"),
        ("codex", "npx -y @agentclientprotocol/codex-acp@\(PackageRange.codex)"),
        ("claude", "npx -y @agentclientprotocol/claude-agent-acp@\(PackageRange.claude)"),
        ("gemini", "gemini --acp"),
        ("cursor", "cursor-agent acp"),
        ("copilot", "copilot --acp --stdio"),
        // Its interaction questions are cancelled rather than answered — see
        // ``AntigravityCompat``.
        ("antigravity", antigravityCommand),
        ("devin", "devin acp"),
        ("droid", "droid exec --output-format acp"),
        ("fast-agent", "uvx fast-agent-mcp acp"),
        ("fx", "fx acp"),
        ("grok-build", "grok agent stdio"),
        ("iflow", "iflow --experimental-acp"),
        ("junie", "junie --acp=true"),
        ("kilocode", "npx -y @kilocode/cli acp"),
        ("kimi", "kimi acp"),
        ("kiro", "kiro-cli-chat acp"),
        ("mcode", "mcode acp"),
        ("mux", "npx -y mux@\(PackageRange.mux) acp"),
        ("opencode", "npx -y opencode-ai acp"),
        ("pool", "pool acp"),
        ("qoder", "qodercli --acp"),
        ("qwen", "qwen --acp"),
        ("trae", "traecli acp serve"),
        ("zeroclaw", "zeroclaw acp")
    ]

    /// Antigravity ships a different entrypoint per platform, so the registry resolves
    /// it the way upstream's `process.platform` switch does: an `.exe` on Windows, and
    /// on Linux the `.par` plus the `--uid=` argument its launcher requires. The spawn
    /// client builds for all three desktop platforms, so this cannot be a macOS literal.
    private static let antigravityCommand: String = {
        #if os(Windows)
        return "agy_acp_server.exe"
        #elseif os(Linux)
        return "agy_acp_server.par --uid="
        #else
        return "agy_acp_server.par"
        #endif
    }()

    /// agent name → launch command line (unordered lookup view of ``ordered``).
    public static let builtIn: [String: String] =
        Dictionary(uniqueKeysWithValues: ordered.map { ($0.name, $0.command) })

    /// Agent name aliases resolved before lookup. Mirrors acpx's `AGENT_ALIASES`.
    public static let aliases: [String: String] = [
        "factory-droid": "droid", "factorydroid": "droid"
    ]

    /// Built-in agent names in registry order (for `--help` and listings).
    public static var orderedNames: [String] { ordered.map(\.name) }

    /// Direct adapter binary names, tried on `PATH` before the npx fallback.
    private static let preferredBinaries: [String: String] = [
        "claude": "claude-agent-acp",
        "codex": "codex-acp"
    ]

    public static let defaultAgent = "codex"

    public static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static var availableNames: [String] {
        orderedNames
    }

    /// The command line for an agent, honouring user overrides and built-in
    /// aliases. Returns `nil` for an unknown name with no override (caller may
    /// treat it as a literal command).
    public static func command(for name: String, overrides: [String: String] = [:]) -> String? {
        let key = normalize(name)
        if let override = overrides[key], !override.isEmpty { return override }
        if let direct = builtIn[key] { return direct }
        if let alias = aliases[key] { return builtIn[alias] }
        return nil
    }

    /// Resolve a runnable launch spec for the given agent.
    ///
    /// - If a preferred adapter binary is installed, launch it directly.
    /// - Otherwise split the registry command line into executable + arguments.
    /// - An unknown name with no override is treated as a literal command line.
    public static func launch(
        for name: String,
        cwd: String? = nil,
        environment: [String: String]? = nil,
        inheritStderr: Bool = true,
        overrides: [String: String] = [:]
    ) -> ProcessLaunch {
        let key = normalize(name)
        // codex-acp only reaches a system codex through `CODEX_PATH`; when the
        // caller hasn't set one, point it at a `codex` on the child's `PATH` (see
        // ``injectingCodexPath(environment:resolveCodex:)``). Gated on the codex
        // key, and the helper only scans when `CODEX_PATH` is absent, so no other
        // launch pays for the `PATH` scan.
        let environment =
            key == "codex" ? injectingCodexPath(environment: environment) : environment

        if let binary = preferredBinaries[key], let path = which(binary) {
            return ProcessLaunch(
                executable: path, arguments: [], environment: environment,
                workingDirectory: cwd, inheritStderr: inheritStderr)
        }

        let commandLine = command(for: key, overrides: overrides) ?? name
        let tokens = splitCommandLine(commandLine)
        let executable = tokens.first ?? name
        let arguments = Array(tokens.dropFirst())
        return ProcessLaunch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: cwd, inheritStderr: inheritStderr)
    }

    /// Point the codex adapter at a system `codex` when the caller hasn't.
    ///
    /// `codex-acp` spawns its *bundled* `@openai/codex` unless `CODEX_PATH` is
    /// set, and its ACP-server path never searches `PATH` itself (only its
    /// `login` subcommand does). The bundled build can lag the installed codex
    /// and — under macOS XProtect def 5347 — has been quarantined as a false
    /// positive, so `initialize` dies with an opaque "Codex process has exited
    /// with code 1". When `CODEX_PATH` isn't already set and a `codex` is found,
    /// point the adapter at it; an explicit `CODEX_PATH` (including one
    /// deliberately pointing at the bundled build) always wins and short-circuits
    /// the lookup entirely — so a configured launch never pays for a `PATH` scan.
    ///
    /// `resolveCodex` locates a `codex` given the `PATH` the child will run with
    /// (not the parent's, which can differ for a caller-supplied environment); it
    /// defaults to a `PATH` scan and is injectable so the wiring can be tested
    /// without touching the filesystem. A non-`nil` environment is a *full
    /// replacement* for the child (see `ProcessLaunch`), so a `nil` (inherit)
    /// environment is only materialized when a key is actually added — the
    /// unchanged cases return the original, preserving inherit semantics. See
    /// issue #11 / openclaw/acpx#434.
    public static func injectingCodexPath(
        environment: [String: String]?,
        resolveCodex: (_ searchPath: String?) -> String? = { which("codex", in: $0) }
    ) -> [String: String]? {
        let resolved = environment ?? ProcessInfo.processInfo.environment
        guard resolved["CODEX_PATH"] == nil else { return environment }
        guard let codex = resolveCodex(resolved["PATH"]) else { return environment }
        var augmented = resolved
        augmented["CODEX_PATH"] = codex
        return augmented
    }

    /// Split a command line on whitespace, honouring simple single/double quotes.
    public static func splitCommandLine(_ commandLine: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in commandLine {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Locate an executable by name on a `PATH`.
    ///
    /// `searchPath` defaults to this process's `PATH`; pass the `PATH` of the
    /// environment a child will actually run with when they can differ (e.g. the
    /// codex lookup searches the spawned agent's `PATH`, not the parent's).
    public static func which(_ command: String, in searchPath: String? = nil) -> String? {
        let path = searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
