import ACPXCore
import Foundation

/// skillflag's `skill-install` as `--skill install` runs it (`runInstallCli`), given the bundle of
/// each skill named: each skill installed where an agent keeps its skills for a scope — the one
/// `--agent` and the one `--scope` given — and reported on stderr once all are.
enum SkillInstall {
    typealias Failure = Skillflag.Failure

    /// The agents skill-install installs for (`AGENTS`), in its order.
    static let agents = [
        "codex", "claude", "portable", "vscode", "copilot", "amp", "goose", "opencode", "factory", "cursor"
    ]

    /// The scopes it installs in (`SCOPES`).
    static let scopes = ["repo", "user", "cwd"]

    /// The scopes `agent` has skills in, in skillflag's order (`scopeResolversByAgent`).
    static func supportedScopes(_ agent: String) -> [String] {
        switch agent {
        case "codex": ["repo", "cwd", "user"]
        case "vscode", "copilot", "cursor": ["repo"]
        default: ["repo", "user"]
        }
    }

    /// skill-install's usage, which `--help` prints and a missing flag ends with.
    static let usage = """
        Usage:
          skill-install [PATH ...] [--agent <agent>] [--scope <scope>] [--force]

        Input:
          PATH ...            Skill directory path(s) containing SKILL.md.
          stdin tar stream    If PATH is omitted, reads a tar bundle from stdin.

        Options:
          --agent <value>     Target agent (single value).
                              Supported agents: \(agents.joined(separator: ", "))
          --scope <value>     Target scope (single value).
                              Supported scopes: \(scopes.joined(separator: ", "))
          --force             Overwrite destination if it already exists.
          -h, --help          Show this help.

        Behavior:
          If --agent or --scope is missing and an interactive TTY is available,
          the installer launches a wizard to collect missing values.
          CLI flags accept only one --agent and one --scope.
          Use the wizard to select multiple agents/scopes.
        """

    /// Installs the skills `ids` names with skill-install's `arguments`, returning the exit code. A
    /// failure is its message on stderr, once standard input is drained unless it is a terminal.
    static func run(ids: [String], arguments: [String], context: Skillflag.Context) -> Int32 {
        do {
            let options = try Options(arguments)
            if options.help {
                Console.out(usage + "\n")
                if !context.stdinIsTerminal { context.drainStdin() }
                return ExitCodes.success
            }
            guard options.paths.isEmpty else { throw Failure("PATH cannot be used when install input is preset.") }
            let (agents, scopes) = try options.required()
            let plan = try plan(ids: ids, agents: agents, scopes: scopes, context: context)
            let installed = try plan.map { target in
                let (skill, path) = try install(target, force: options.force, context: context)
                return "Installed \(skill) to \(path) (\(target.agent)/\(target.scope))\n"
            }
            installed.forEach(Console.err)
            return ExitCodes.success
        } catch {
            if !context.stdinIsTerminal { context.drainStdin() }
            Console.err(((error as? Failure)?.message ?? error.localizedDescription) + "\n")
            return ExitCodes.error
        }
    }

    /// skill-install's arguments (`parseArgs`): the one `--agent` and the one `--scope`, `--force`,
    /// `--help` and the paths of skills to install.
    struct Options: Equatable {
        var paths: [String] = []
        var agent: String?
        var scope: String?
        var force = false
        var help = false

        init(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch argument {
                case "--agent":
                    guard agent == nil else { throw Failure("Only one --agent flag is allowed.") }
                    agent = try Self.single(value, flag: "--agent")
                    index += 1
                case "--scope":
                    guard scope == nil else { throw Failure("Only one --scope flag is allowed.") }
                    scope = try Self.single(value, flag: "--scope")
                    index += 1
                case "--force":
                    force = true
                case "--help", "-h":
                    help = true
                default:
                    guard !argument.hasPrefix("-") else { throw Failure("Unknown option: \(argument)") }
                    paths.append(argument)
                }
                index += 1
            }
        }

        /// `parseAgentValue` and `parseScopeValue`: the flag's value, trimmed — one, not a list.
        private static func single(_ value: String?, flag: String) throws -> String {
            guard let value, !value.isEmpty, !value.hasPrefix("-"), !value.javaScriptTrimmed.isEmpty else {
                throw Failure("Missing value for \(flag).")
            }
            guard !value.contains(",") else {
                throw Failure("Only one value is allowed for \(flag). Comma-separated values are not supported.")
            }
            return value.javaScriptTrimmed
        }

        /// `validateRequiredFlags`: the agent and the scope, both given and supported together.
        func required() throws -> (agents: [String], scopes: [String]) {
            guard let agent, let scope else { throw Failure("Missing required flags.\n\(SkillInstall.usage)") }
            guard SkillInstall.agents.contains(agent) else { throw Failure("Unsupported agent: \(agent)") }
            guard SkillInstall.scopes.contains(scope) else { throw Failure("Unsupported scope: \(scope)") }
            guard supportedScopes(agent).contains(scope) else {
                throw Failure("Unsupported agent/scope: \(agent) \(scope)")
            }
            return ([agent], [scope])
        }
    }

    /// One skill to install for one agent in one scope, where skill-install plans it: under the
    /// agent's skills in that scope, by the skill's name as given.
    struct Target {
        let skill: String
        let agent: String
        let scope: String
        let destination: String
    }

    /// `buildInstallPlan`: each skill for each agent in each scope.
    static func plan(ids: [String], agents: [String], scopes: [String], context: Skillflag.Context) throws -> [Target] {
        try ids.flatMap { skill in
            try agents.flatMap { agent in
                try scopes.map { scope in
                    let root = try skillsRoot(agent: agent, scope: scope, context: context)
                    return Target(skill: skill, agent: agent, scope: scope, destination: NodePath.joined(root, skill))
                }
            }
        }
    }

    /// `resolveSkillsRoot`: where `agent` keeps its skills in `scope` — under the git work tree `cwd`
    /// is in, `cwd` itself, or the user's own directories. Relative when what it comes from is.
    static func skillsRoot(agent: String, scope: String, context: Skillflag.Context) throws -> String {
        guard supportedScopes(agent).contains(scope) else {
            throw Failure("Unsupported agent/scope: \(agent) \(scope)")
        }
        let environment = context.environment
        if scope == "user" {
            let home = homeDirectory(environment)
            let configRoot = environment["XDG_CONFIG_HOME"] ?? NodePath.joined(home, ".config")
            switch agent {
            case "codex":
                return NodePath.joined(environment["CODEX_HOME"] ?? NodePath.joined(home, ".codex"), "skills")
            case "claude": return NodePath.joined(home, ".claude/skills")
            case "opencode": return NodePath.joined(configRoot, "opencode/skill")
            case "factory": return NodePath.joined(home, ".factory/skills")
            default: return NodePath.joined(configRoot, "agents/skills")
            }
        }
        let base = scope == "cwd" ? context.cwd : repoRoot(context)
        switch agent {
        case "codex": return NodePath.joined(base, ".codex/skills")
        case "claude": return NodePath.joined(base, ".claude/skills")
        case "vscode", "copilot": return NodePath.joined(base, ".github/skills")
        case "opencode": return NodePath.joined(base, ".opencode/skill")
        case "factory": return NodePath.joined(base, ".factory/skills")
        case "cursor": return NodePath.joined(base, ".cursor/skills")
        default: return NodePath.joined(base, ".agents/skills")
        }
    }

    /// Node's `os.homedir()`: `HOME` when set, however empty, else the user's home in the password file.
    static func homeDirectory(_ environment: [String: String]) -> String {
        if let home = environment["HOME"] { return home }
        guard let entry = getpwuid(geteuid()), let directory = entry.pointee.pw_dir else { return "" }
        return String(cString: directory)
    }

    /// `resolveRepoRoot`: the top of the git work tree the directory is in, as `git rev-parse
    /// --show-toplevel` prints it; the directory itself when git fails or is nowhere on the `PATH`.
    /// What git says on stderr is passed on, as Node's `execFileSync` passes it on.
    static func repoRoot(_ context: Skillflag.Context) -> String {
        guard let git = executable("git", path: context.environment["PATH"] ?? "/usr/bin:/bin") else {
            return context.cwd
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: context.cwd)
        process.environment = context.environment
        let (output, errors) = (Pipe(), Pipe())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return context.cwd }
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !said.isEmpty { Console.errBytes(said) }
        let root = String(decoding: printed, as: UTF8.self).javaScriptTrimmed
        return process.terminationStatus == 0 && !root.isEmpty ? root : context.cwd
    }

    /// The first executable file `name` in the directories of `path`, as a spawn looks it up.
    private static func executable(_ name: String, path: String) -> String? {
        path.split(separator: ":", omittingEmptySubsequences: false)
            .map { ($0.isEmpty ? "." : String($0)) + "/" + name }
            .first { candidate in
                var status = stat()
                return stat(candidate, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
                    && access(candidate, X_OK) == 0
            }
    }
}
