import Foundation
import SwiftACP

/// acpx's `builtin-command-migration.ts`: the command lines built-in agents were launched
/// with before, and a saved launch identity under one of them read as the current one
/// (acpx 0.19.4, openclaw/acpx#838).
///
/// A session record keeps the `agent_command` it was created under. When a built-in's
/// default changes — acpx moves an adapter's package range — the records saved under the
/// earlier default would drop out of the built-in's scope; instead they are read as the
/// current default, and saved under it the next time they are written.
public enum BuiltInCommandMigration {
    /// Every command string a built-in agent has shipped with: acpx's `legacyFallbackCommands`
    /// and `LEGACY_AGENT_COMMANDS`. Saved session records keep the command they were created
    /// under, so a range change in ``AgentRegistry/PackageRange`` must add the previous
    /// command here or those sessions drop out of agent-scoped lookup.
    public static let legacyCommands: [(name: String, commands: [String])] = [
        ("claude", ["npm exec @agentclientprotocol/claude-agent-acp@\(AgentRegistry.PackageRange.claude)"]),
        ("pi", ["npx pi-acp", "npx pi-acp@^0.0.22", "npx pi-acp@^0.0.26", "npx pi-acp@^0.0.31"]),
        ("codex", [
            "npx @zed-industries/codex-acp", "npx @zed-industries/codex-acp@^0.9.5",
            "npx @zed-industries/codex-acp@^0.10.0", "npx @zed-industries/codex-acp@^0.11.1",
            "npx @zed-industries/codex-acp@^0.12.0", "npx -y @agentclientprotocol/codex-acp@^0.0.44",
            "npx -y @agentclientprotocol/codex-acp@^1.1.4"
        ]),
        ("claude", [
            "npx @zed-industries/claude-agent-acp", "npx -y @zed-industries/claude-agent-acp",
            "npx -y @zed-industries/claude-agent-acp@^0.21.0", "npx -y @zed-industries/claude-agent-acp@^0.23.1",
            "npx -y @zed-industries/claude-agent-acp@^0.24.2", "npx -y @zed-industries/claude-agent-acp@^0.25.0",
            "npx -y @zed-industries/claude-agent-acp@^0.31.0",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.24.2",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.25.0",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.31.0",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.36.1",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.37.0",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.60.0",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.76.0",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.25.0",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.31.0",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.36.1",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.37.0",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.60.0",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.76.0"
        ]),
        ("gemini", ["gemini", "gemini --experimental-acp"]),
        ("kiro", ["kiro-cli acp"]),
        ("mux", ["npx -y mux@^0.27.0 acp"]),
        ("opencode", ["npx opencode-ai"])
    ]

    /// A record's launch identity: its `agent_command`, and its `agent_argv` when it has one.
    public struct Identity: Equatable, Sendable {
        public var command: String
        public var argv: [String]?

        public init(command: String, argv: [String]?) {
            self.command = command
            self.argv = argv
        }
    }

    /// acpx's `builtInAgentForCommand`: the built-in agent whose current or earlier default
    /// command is exactly `command`.
    static func builtInAgent(forCommand command: String) -> String? {
        AgentRegistry.ordered.first { $0.command == command }?.name
            ?? legacyCommands.first { $0.commands.contains(command) }?.name
    }

    /// acpx's `resolveAgentArgvForCommand`: the argv of the built-in agent `command` launches,
    /// under its current command line or one it had before.
    static func argv(forCommand command: String) -> [String]? {
        builtInAgent(forCommand: command).flatMap(AgentRegistry.argv(for:))
    }

    /// acpx's `migrateBuiltInAgentIdentity`: a launch identity saved under an earlier
    /// built-in default, read as the current built-in command and argv, so agent-scoped
    /// lookup keeps finding the session after an adapter range change. An identity with a
    /// custom argv, and a command acpx never shipped as a built-in default, come back
    /// unchanged.
    public static func migrated(command: String, argv: [String]?) -> Identity {
        guard let name = builtInAgent(forCommand: command), let current = AgentRegistry.builtIn[name],
            current != command, launchesBuiltIn(command: command, argv: argv, name: name)
        else { return Identity(command: command, argv: argv) }
        return Identity(command: current, argv: AgentRegistry.argv(for: name))
    }

    /// acpx's `launchesBuiltIn`: the saved argv is absent, is the saved command's own words,
    /// or is the built-in's current argv — anything else is a custom launcher.
    private static func launchesBuiltIn(command: String, argv: [String]?, name: String) -> Bool {
        guard let argv else { return true }
        return argv == AgentRegistry.splitCommandLine(command) || argv == (AgentRegistry.argv(for: name) ?? [])
    }

    /// acpx's `canonicalAgentCommand`: the command a session saved under `command` is filed
    /// under after migration.
    public static func canonicalAgentCommand(_ command: String) -> String {
        migrated(command: command, argv: nil).command
    }

    /// acpx's `agentScope`: the commands a scoped query matches — the query itself, plus the
    /// current built-in command when the query is an earlier built-in default (records under
    /// it are migrated on read unless they carry a custom launcher), so `--agent <earlier
    /// default>` finds both.
    public static func scope(_ command: String) -> Set<String> {
        [command, canonicalAgentCommand(command)]
    }
}
