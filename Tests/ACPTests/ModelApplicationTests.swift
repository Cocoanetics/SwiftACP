@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// `--config-option` on one-shot `exec`, and the model application it is ordered
/// against (acpx 0.14.0). Verified against real acpx 0.19.1 driving an agent that
/// advertises a model select plus a plain select: the requested model goes first,
/// then each option in the order given, then the prompt.
struct ModelApplicationTests {
    // MARK: - Parsing `<key>=<value>`

    @Test func assignmentSplitsOnTheFirstEqualsAndTrimsBothHalves() throws {
        let parsed = try parseSessionConfigOptionAssignment("  effort  =  high  ")
        #expect(parsed == ModelApplication.ConfigOptionAssignment(configId: "effort", value: "high"))
        // Only the *first* `=` separates, so a value may contain more of them.
        let nested = try parseSessionConfigOptionAssignment("filter=a=b")
        #expect(nested == ModelApplication.ConfigOptionAssignment(configId: "filter", value: "a=b"))
    }

    @Test func malformedAssignmentsCarryAcpxsMessage() {
        for input in ["noequals", "=value", "key=", "", "=", "   =  value", "key=   "] {
            let error = #expect(throws: UsageError.self, "\(input)") {
                try parseSessionConfigOptionAssignment(input)
            }
            #expect(
                error?.message == #"Session config option must use "<key>=<value>" with non-empty parts"#,
                "\(input)")
        }
    }

    /// acpx collects `--config-option`; the scanner's default last-wins would
    /// silently drop every selection but the final one.
    @Test func repeatedOptionsKeepEveryOccurrenceInOrder() throws {
        let (options, arguments) = try Self.exec(["--config-option", "a=1", "--config-option=b=2", "hi"])
        #expect(options.strings("config-option") == ["a=1", "b=2"])
        #expect(arguments == ["hi"])
    }

    @Test func nonRepeatableOptionsStillTakeTheLastValue() throws {
        let (options, _) = try Self.exec(["--file", "one", "--file", "two"])
        #expect(options.string("file") == "two")
        #expect(options.strings("file").isEmpty)
    }

    /// `acpx exec <args>`, parsed: the options given to `exec`, and its arguments.
    private static func exec(_ args: [String]) throws -> (ScannedArgs, [String]) {
        guard case .run(let levels, let arguments) = try Commander.parse(
            ["exec"] + args, root: CommandTree.acpx(agents: []))
        else { throw CancellationError() }
        return (levels.last?.options ?? ScannedArgs(), arguments)
    }

    // MARK: - Validating a requested model

    private func advertised(_ ids: [String], current: String = "m1") -> ModelSupport.ModelState {
        ModelSupport.ModelState(
            configId: "model", currentModelId: current,
            availableModels: ids.map { (modelId: $0, name: $0.uppercased()) })
    }

    @Test func anUnadvertisedModelIsRefusedWithTheAdvertisedList() {
        let error = #expect(throws: ModelApplication.UnsupportedError.self) {
            try ModelApplication.assertRequestedModelSupported(
                requestedModel: "bogus", models: advertised(["m1", "m2"]),
                agentCommand: "probe", context: .apply)
        }
        #expect(error?.message == """
            Cannot apply --model "bogus": the ACP agent did not advertise that model. \
            Available models: m1, m2.
            """)
        #expect(error?.reason == .unadvertisedModel)
    }

    /// The only difference a replay makes is the verb.
    @Test func replayNamesItselfInTheSameRefusal() {
        let error = #expect(throws: ModelApplication.UnsupportedError.self) {
            try ModelApplication.assertRequestedModelSupported(
                requestedModel: "bogus", models: advertised(["m1"]),
                agentCommand: "probe", context: .replay)
        }
        #expect(error?.message.hasPrefix(#"Cannot replay saved model "bogus""#) == true)
    }

    @Test func anAgentThatAdvertisesNoModelsCannotTakeOne() {
        let error = #expect(throws: ModelApplication.UnsupportedError.self) {
            try ModelApplication.assertRequestedModelSupported(
                requestedModel: "m1", models: nil, agentCommand: "probe", context: .apply)
        }
        #expect(error?.reason == .missingCapability)
        #expect(error?.message.contains("does not support a startup model flag") == true)
    }

    /// Claude Code takes models the ACP layer never advertised, so acpx forwards
    /// them rather than refusing — silently when nothing was advertised at all,
    /// with a warning when a list was advertised and the model wasn't on it.
    @Test func claudeCodeIsAllowedToDecideForItself() throws {
        let claude = "npx @agentclientprotocol/claude-agent-acp"
        #expect(try ModelApplication.assertRequestedModelSupported(
            requestedModel: "opus", models: nil, agentCommand: claude, context: .apply) == nil)
        let warning = try ModelApplication.assertRequestedModelSupported(
            requestedModel: "opus", models: advertised(["m1", "m2"]),
            agentCommand: claude, context: .apply)
        #expect(warning?.contains("forwarding it to Claude Code") == true)
        #expect(warning?.contains("(m1, m2)") == true)
    }

    @Test func cursorResolvesABareIdToItsSingleSuffixedModel() throws {
        let models = advertised(["gpt-5[thinking]", "sonnet-4.5"])
        let resolved = try ModelApplication.resolveRequestedModelId(
            "gpt-5", models: models, agentCommand: "cursor-agent")
        #expect(resolved == "gpt-5[thinking]")
        // The warning says which id actually went out.
        let warning = try ModelApplication.assertRequestedModelSupported(
            requestedModel: "gpt-5", models: models, agentCommand: "cursor-agent", context: .apply)
        #expect(warning == """
            Cursor ACP advertised "gpt-5[thinking]" for requested model "gpt-5"; \
            using the advertised id.
            """)
        // Same list, a non-Cursor adapter: no alias, so the id is simply unadvertised.
        #expect(throws: ModelApplication.UnsupportedError.self) {
            try ModelApplication.assertRequestedModelSupported(
                requestedModel: "gpt-5", models: models, agentCommand: "probe", context: .apply)
        }
    }

    @Test func anAmbiguousCursorAliasIsRefusedRatherThanGuessed() {
        let error = #expect(throws: ModelApplication.UnsupportedError.self) {
            try ModelApplication.resolveRequestedModelId(
                "gpt-5", models: advertised(["gpt-5[thinking]", "gpt-5[fast]"]),
                agentCommand: "cursor-agent")
        }
        #expect(error?.ambiguous == true)
        #expect(error?.message.contains("multiple advertised Cursor models match") == true)
    }

    /// acpx 0.19.4's `resolveRequestedConfigOption` (openclaw/acpx#807): only the model's own
    /// option takes its value as a model id, resolved as `--model` resolves one.
    @Test func onlyTheModelsOptionResolvesItsValueAsAModelId() throws {
        let models = advertised(["gpt-5[thinking]", "m1"])
        #expect(try ModelApplication.resolveRequestedConfigOption(
            "model", value: "gpt-5", models: models, agentCommand: "cursor-agent") == "gpt-5[thinking]")
        #expect(try ModelApplication.resolveRequestedConfigOption(
            "effort", value: "gpt-5", models: models, agentCommand: "cursor-agent") == "gpt-5")
        #expect(try ModelApplication.resolveRequestedConfigOption(
            "model", value: "gpt-5", models: models, agentCommand: "probe") == "gpt-5")
        #expect(try ModelApplication.resolveRequestedConfigOption(
            "model", value: "gpt-5", models: nil, agentCommand: "cursor-agent") == "gpt-5")
    }

    // MARK: - Recording a selection

    /// The catalog acpx's `owned-controls.test.ts` gives a Cursor session: on `m1`, with
    /// `gpt-5[thinking]` beside it.
    private static func cursorCatalog() -> SessionAcpxState {
        var state = SessionAcpxState()
        state.configOptions = .array([.object([
            "id": .string("model"), "name": .string("Model"), "type": .string("select"),
            "category": .string("model"), "currentValue": .string("m1"),
            "options": .array([
                .object(["value": .string("m1"), "name": .string("One")]),
                .object(["value": .string("gpt-5[thinking]"), "name": .string("Thinking")])
            ])
        ])])
        return state
    }

    /// acpx 0.19.4 (openclaw/acpx#807, `owned-controls.test.ts`): a model set by its alias and
    /// acknowledged with `{}` is current as the id that went out, which the option's value
    /// takes too, while `session_options` keeps the alias — the preference a reconnect
    /// replays — whether it was set as the model or as the model's option.
    @Test(arguments: [false, true])
    func anAcknowledgedAliasIsRecordedAsTheIdThatWentOut(throughOption: Bool) {
        var state = Self.cursorCatalog()
        let acknowledgement = SetSessionConfigOptionResponse()
        if throughOption {
            ModelSupport.applyConfigOptionSelection(
                "model", value: "gpt-5", resolvedTo: "gpt-5[thinking]", response: acknowledgement, to: &state)
        } else {
            ModelSupport.applyModelSelection(
                "gpt-5", resolvedTo: "gpt-5[thinking]", response: acknowledgement, to: &state)
        }
        #expect(state.currentModelId == "gpt-5[thinking]")
        #expect(state.configOptions?.arrayValue?.first?.dictionaryValue?["currentValue"] == .string("gpt-5[thinking]"))
        #expect(state.sessionOptions?.model == "gpt-5")
    }

    /// Without a resolved id the model went out as asked, and is recorded so.
    @Test func aModelThatWentOutAsAskedIsRecordedAsAsked() {
        var state = Self.cursorCatalog()
        ModelSupport.applyModelSelection("gpt-5[thinking]", response: SetSessionConfigOptionResponse(), to: &state)
        #expect(state.currentModelId == "gpt-5[thinking]")
        #expect(state.sessionOptions?.model == "gpt-5[thinking]")
    }

    @Test func anEmptyModelListReadsAsNoneAdvertised() {
        #expect(ModelApplication.formatAvailableModelIds(nil) == "none advertised")
        #expect(ModelApplication.formatAvailableModelIds(advertised([])) == "none advertised")
        // Blank ids are dropped rather than printed as empty entries.
        #expect(ModelApplication.formatAvailableModelIds(advertised(["m1", "  "])) == "m1")
    }

    @Test func adapterShapesAreRecognizedThroughTheirCommandLine() {
        #expect(ModelApplication.basenameToken("/opt/bin/Cursor-Agent.EXE") == "cursor-agent")
        #expect(ModelApplication.isCursorAcpCommandForModelAlias("agent acp"))
        #expect(!ModelApplication.isCursorAcpCommandForModelAlias("agent"))
        #expect(ModelApplication.supportsLegacyClaudeCodeModelMetadata("claude-agent-acp"))
        #expect(ModelApplication.supportsLegacyClaudeCodeModelMetadata("npx claude-agent-acp@0.7"))
        #expect(!ModelApplication.supportsLegacyClaudeCodeModelMetadata("codex-acp"))
        #expect(!ModelApplication.supportsLegacyClaudeCodeModelMetadata(nil))
    }

    /// A configured agent's command line carries its args — acpx's `command` plus each
    /// `quoteCommandArg`, or `renderArgvIdentity` — so an entry launching the adapter
    /// through `npx` is still Claude's (#95 review).
    @Test(arguments: [
        #"{"command":"npx","args":["-y","@agentclientprotocol/claude-agent-acp"]}"#,
        #"{"argv":["npx","-y","@agentclientprotocol/claude-agent-acp"]}"#
    ])
    func aConfiguredAgentIsKnownByItsArgs(entry: String) throws {
        let agent = try ConfigFields.agent(try WireJSON.parse(entry), name: "claude", "config.json")
        #expect(ModelApplication.supportsLegacyClaudeCodeModelMetadata(agent.command))
    }
}
