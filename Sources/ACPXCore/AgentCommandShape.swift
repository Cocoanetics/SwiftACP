import Foundation
import SwiftACP

/// Recognizing an adapter from the command line that launches it, ported from
/// acpx `acp/agent-command.ts`.
///
/// acpx keys a handful of compatibility behaviours off the *shape* of the
/// configured command rather than the agent's registry name, so an adapter
/// reached through `--agent` or a custom config entry is treated the same way a
/// built-in one is.
public enum AgentCommandShape {
    /// acpx's `basenameToken`: the lowercased file name with a Windows
    /// executable suffix dropped. Node's `path.basename` is platform-dependent,
    /// so a backslash only separates on Windows.
    public static func basenameToken(_ value: String) -> String {
        var name = (value as NSString).lastPathComponent
        #if os(Windows)
            if let backslash = name.lastIndex(of: "\\") {
                name = String(name[name.index(after: backslash)...])
            }
        #endif
        name = name.lowercased()
        for suffix in [".cmd", ".exe", ".bat"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// Claude Code's ACP adapter — launched directly, or (as the registry does)
    /// through `npx @agentclientprotocol/claude-agent-acp@<range>`.
    public static func isClaudeAcpCommand(_ agentCommand: String?) -> Bool {
        guard let (command, args) = shape(agentCommand) else { return false }
        if basenameToken(command) == "claude-agent-acp" { return true }
        return args.contains { $0.contains("claude-agent-acp") }
    }

    /// Cursor's ACP adapter, which advertises suffixed model ids.
    public static func isCursorAcpCommand(_ agentCommand: String?) -> Bool {
        guard let (command, args) = shape(agentCommand) else { return false }
        let token = basenameToken(command)
        return token == "cursor-agent" || (token == "agent" && args.contains("acp"))
    }

    private static func shape(_ agentCommand: String?) -> (String, [String])? {
        guard let agentCommand, !agentCommand.isEmpty else { return nil }
        let tokens = AgentRegistry.splitCommandLine(agentCommand)
        guard let command = tokens.first else { return nil }
        return (command, Array(tokens.dropFirst()))
    }
}
