@testable import ACPXCore
import Foundation
import JSONFoundation
import Testing

/// The `_meta` on `session/new`. Despite the `claudeCode` key, acpx sends the
/// invocation's session options for *every* agent — only `settingSources` is
/// gated on the adapter being Claude Code's. Each expectation below was captured
/// from npm acpx 0.19.1 against the same flags.
struct SessionMetaTests {
    private func options(
        model: String? = nil, allowedTools: [String]? = nil, maxTurns: Int? = nil,
        systemPrompt: JSONValue? = nil
    ) -> SessionAcpxState.SessionOptions {
        var options = SessionAcpxState.SessionOptions()
        options.model = model
        options.allowedTools = allowedTools
        options.maxTurns = maxTurns
        options.systemPrompt = systemPrompt
        return options
    }

    /// `JSONValue` is `ExpressibleByNilLiteral`, so `build(…) == nil` compares
    /// against `.some(.null)` — "a `_meta` whose value is JSON null" — rather than
    /// "no `_meta` at all". Absence has to be matched explicitly.
    private func isAbsent(_ meta: JSONValue?) -> Bool {
        if case .none = meta { return true }
        return false
    }

    private let codex = "npx -y @zed-industries/codex-acp@^1.1.5"
    private let claude = "npx -y @agentclientprotocol/claude-agent-acp@^0.76.0"

    @Test func nothingRequestedMeansNoMetaAtAll() {
        #expect(isAbsent(SessionMeta.build(options: nil, agentCommand: codex, environment: [:])))
        #expect(isAbsent(SessionMeta.build(options: options(), agentCommand: codex, environment: [:])))
    }

    /// The gate this fixes: a non-claude agent used to get no `_meta` at all.
    @Test func sessionOptionsReachEveryAgent() {
        let meta = SessionMeta.build(
            options: options(model: "m1", allowedTools: ["Read"], maxTurns: 2),
            agentCommand: codex, environment: [:])
        #expect(meta == .object(["claudeCode": .object(["options": .object([
            "model": .string("m1"),
            "allowedTools": .array([.string("Read")]),
            "maxTurns": .integer(2)
        ])])]))
    }

    /// `systemPrompt` sits at the top level of `_meta`, not beside the others.
    @Test func theSystemPromptSitsOutsideClaudeCodeOptions() {
        let replace = SessionMeta.build(
            options: options(systemPrompt: .string("be terse")), agentCommand: codex,
            environment: [:])
        #expect(replace == .object(["systemPrompt": .string("be terse")]))

        let append = SessionMeta.build(
            options: options(systemPrompt: .object(["append": .string("also this")])),
            agentCommand: codex, environment: [:])
        #expect(append == .object(["systemPrompt": .object(["append": .string("also this")])]))

        // Alongside options, both blocks appear.
        let both = SessionMeta.build(
            options: options(model: "m1", systemPrompt: .string("sp")), agentCommand: codex,
            environment: [:])
        #expect(both == .object([
            "claudeCode": .object(["options": .object(["model": .string("m1")])]),
            "systemPrompt": .string("sp")
        ]))
    }

    @Test func emptyOrMalformedSystemPromptsAreDropped() {
        for value: JSONValue in [.string(""), .object([:]), .object(["append": .string("")]),
                                 .object(["append": .integer(1)]), .integer(3), .null] {
            #expect(
                isAbsent(SessionMeta.build(
                    options: options(systemPrompt: value), agentCommand: codex, environment: [:])),
                "\(value)")
        }
    }

    /// acpx skips a blank `--model` rather than sending an empty selection.
    @Test func aBlankModelIsNotSent() {
        #expect(isAbsent(SessionMeta.build(
            options: options(model: "   "), agentCommand: codex, environment: [:])))
    }

    /// `settingSources` isolates an automated run from the operator's personal
    /// Claude settings, and is the one part that *is* claude-only.
    @Test func settingSourcesAreClaudeOnlyAndEnvironmentGated() {
        let plain = SessionMeta.build(options: nil, agentCommand: claude, environment: [:])
        #expect(plain == .object(["claudeCode": .object(["options": .object([
            "settingSources": .array([.string("project"), .string("local")])
        ])])]))

        let withUser = SessionMeta.build(
            options: nil, agentCommand: claude,
            environment: ["ACPX_CLAUDE_INCLUDE_USER_SETTINGS": " 1 "])
        #expect(withUser == .object(["claudeCode": .object(["options": .object([
            "settingSources": .array([.string("user"), .string("project"), .string("local")])
        ])])]))

        // Any other value leaves the operator's settings out.
        #expect(SessionMeta.settingSources(["ACPX_CLAUDE_INCLUDE_USER_SETTINGS": "true"])
            == ["project", "local"])
        // And a non-claude adapter never gets the key.
        #expect(isAbsent(SessionMeta.build(options: nil, agentCommand: codex, environment: [:])))
    }

    // MARK: - Recognizing the adapter

    @Test func claudeIsRecognizedThroughItsLauncher() {
        #expect(AgentCommandShape.isClaudeAcpCommand(claude))
        #expect(AgentCommandShape.isClaudeAcpCommand("claude-agent-acp"))
        #expect(AgentCommandShape.isClaudeAcpCommand("/opt/bin/Claude-Agent-ACP.exe"))
        #expect(!AgentCommandShape.isClaudeAcpCommand(codex))
        #expect(!AgentCommandShape.isClaudeAcpCommand(nil))
        #expect(!AgentCommandShape.isClaudeAcpCommand(""))
    }

    @Test func cursorIsRecognizedThroughEitherSpelling() {
        #expect(AgentCommandShape.isCursorAcpCommand("cursor-agent"))
        #expect(AgentCommandShape.isCursorAcpCommand("/usr/local/bin/agent acp"))
        #expect(!AgentCommandShape.isCursorAcpCommand("agent"))
        #expect(!AgentCommandShape.isCursorAcpCommand(codex))
    }

    @Test func windowsExecutableSuffixesAreStripped() {
        #expect(AgentCommandShape.basenameToken("/x/CURSOR-AGENT.CMD") == "cursor-agent")
        #expect(AgentCommandShape.basenameToken("agent.bat") == "agent")
        #expect(AgentCommandShape.basenameToken("agent.exe") == "agent")
        // Only those three suffixes; anything else is part of the name.
        #expect(AgentCommandShape.basenameToken("agent.py") == "agent.py")
    }
}
