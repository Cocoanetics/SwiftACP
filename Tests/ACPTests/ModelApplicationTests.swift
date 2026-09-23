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

    // MARK: - Carrying advertised state across responses

    @Test func advertisedStateFollowsTheLatestConfigOptions() {
        let select = JSONValue.object([
            "id": .string("model"), "type": .string("select"), "category": .string("model"),
            "currentValue": .string("m2"),
            "options": .array([.object(["value": .string("m2"), "name": .string("Two")])])
        ])
        let state = ModelApplication.advance(nil, with: [select])
        #expect(state?.currentModelId == "m2")
        // A response with no model option clears config-derived state…
        #expect(ModelApplication.advance(state, with: []) == nil)
        // …but leaves legacy state alone: config options never carried it, so they
        // cannot have withdrawn it.
        let legacy = ModelSupport.ModelState(
            configId: nil, currentModelId: "m1", availableModels: [])
        #expect(ModelApplication.advance(legacy, with: nil)?.currentModelId == "m1")
    }
}
