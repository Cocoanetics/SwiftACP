import Foundation
import JSONFoundation
import SwiftACP

/// Putting a requested model and explicit config options onto a live session.
///
/// Ported from acpx `acp/model-support.ts` (`assertRequestedModelSupported`,
/// `resolveRequestedModelId`), `session/model-application.ts`
/// (`applyRequestedModelIfAdvertised`) and the two `AcpClient` setters that
/// decide which wire method carries a model.
///
/// The split matters because "set the model" is not one request: an agent that
/// advertises its models as a config option takes `session/set_config_option`
/// under that option's id, while one that only advertises legacy `models`
/// metadata takes `session/set_model`.
public enum ModelApplication {
    /// Whether the model came from `--model` on this invocation or from a record
    /// being replayed — it only changes the verb in the error message.
    public enum Context: Sendable {
        case apply
        case replay

        fileprivate var action: String {
            switch self {
            case .apply: return "apply --model"
            case .replay: return "replay saved model"
            }
        }
    }

    /// A requested model the agent can't be asked for: it advertises no model
    /// control at all, or not that model.
    public struct UnsupportedError: LocalizedError, CustomStringConvertible {
        public enum Reason: String, Sendable {
            case missingCapability = "missing-capability"
            case unadvertisedModel = "unadvertised-model"
        }

        public let message: String
        public let reason: Reason
        /// Set when a Cursor alias matched more than one advertised model.
        public let ambiguous: Bool

        public init(_ message: String, reason: Reason, ambiguous: Bool = false) {
            self.message = message
            self.reason = reason
            self.ambiguous = ambiguous
        }

        public var description: String { message }
        public var errorDescription: String? { message }
    }

    /// What applying a requested model came to — acpx's `{ applied, response }`.
    public struct Application: Sendable {
        /// Whether the session is on the requested model now: it was asked for it, or
        /// was on it already. `false` when none was requested or none is advertised.
        public var applied: Bool
        /// The agent's reply, when the model went by its config option.
        public var response: SetSessionConfigOptionResponse?

        public init(applied: Bool, response: SetSessionConfigOptionResponse? = nil) {
            self.applied = applied
            self.response = response
        }
    }

    /// One `<configId>=<value>` selection to put on a session.
    public struct ConfigOptionAssignment: Sendable, Equatable {
        public let configId: String
        public let value: String

        public init(configId: String, value: String) {
            self.configId = configId
            self.value = value
        }
    }

    // MARK: - Applying

    /// Put an invocation's session controls onto a freshly created session, in
    /// acpx's order: the requested model first, then each config option in the
    /// order it was given, then (for the caller) the prompt.
    ///
    /// The model goes first because an agent may re-advertise its options after a
    /// model change — a later option has to resolve against what the agent last
    /// advertised, not against what `session/new` returned.
    ///
    /// Each request goes within `timeoutMilliseconds` (acpx's `--timeout`), when given.
    public static func applySessionControls(
        connection: ACPAgentConnection,
        session: NewSessionResponse,
        model: String?,
        configOptions: [ConfigOptionAssignment],
        agentCommand: String?,
        timeoutMilliseconds: Int? = nil,
        onWarning: ((String) -> Void)? = nil
    ) async throws {
        guard model != nil || !configOptions.isEmpty else { return }
        var state = ModelSupport.modelState(fromConfigOptions: session.configOptions)
            ?? ModelSupport.modelState(fromLegacyModels: session.models)
        let applied = try await applyRequestedModel(
            connection: connection, sessionId: session.sessionId, requestedModel: model,
            models: state, agentCommand: agentCommand, timeoutMilliseconds: timeoutMilliseconds,
            onWarning: onWarning
        ).response
        if let applied { state = advance(state, with: applied.configOptions) }
        let sessionId = session.sessionId
        for option in configOptions {
            let models = state
            let result = try await withTimeout(milliseconds: timeoutMilliseconds) {
                try await setConfigOption(
                    connection: connection, sessionId: sessionId, configId: option.configId,
                    value: option.value, models: models, agentCommand: agentCommand)
            }
            state = advance(state, with: result.configOptions)
        }
    }

    /// Apply `requestedModel` to `sessionId` when the agent advertises it,
    /// returning the `session/set_config_option` response when one was sent.
    ///
    /// Nothing is sent when no model was requested, when the agent advertises no
    /// models, or when the session is already on that model — acpx skips the
    /// request in that last case rather than re-selecting the current model.
    /// A non-fatal mismatch (a Cursor alias, or a model Claude Code may still
    /// accept) is reported through `onWarning`; an unusable one throws.
    public static func applyRequestedModelIfAdvertised(
        connection: ACPAgentConnection,
        sessionId: SessionId,
        requestedModel: String?,
        models: ModelSupport.ModelState?,
        agentCommand: String?,
        onWarning: ((String) -> Void)? = nil
    ) async throws -> SetSessionConfigOptionResponse? {
        try await applyRequestedModel(
            connection: connection, sessionId: sessionId, requestedModel: requestedModel, models: models,
            agentCommand: agentCommand, onWarning: onWarning
        ).response
    }

    /// ``applyRequestedModelIfAdvertised(connection:sessionId:requestedModel:models:agentCommand:onWarning:)``
    /// with whether the model was applied, as acpx's function returns it.
    ///
    /// The request goes within `timeoutMilliseconds` (acpx's `--timeout`), when given.
    public static func applyRequestedModel(
        connection: ACPAgentConnection,
        sessionId: SessionId,
        requestedModel: String?,
        models: ModelSupport.ModelState?,
        agentCommand: String?,
        timeoutMilliseconds: Int? = nil,
        onWarning: ((String) -> Void)? = nil
    ) async throws -> Application {
        let requested = requestedModel?.javaScriptTrimmed ?? ""
        guard !requested.isEmpty else { return Application(applied: false) }
        if let warning = try assertRequestedModelSupported(
            requestedModel: requested, models: models, agentCommand: agentCommand, context: .apply) {
            onWarning?(warning)
        }
        guard let models else { return Application(applied: false) }
        guard models.currentModelId != requested else { return Application(applied: true) }
        let response = try await withTimeout(milliseconds: timeoutMilliseconds) {
            try await setModel(
                connection: connection, sessionId: sessionId, modelId: requested,
                models: models, agentCommand: agentCommand)
        }
        return Application(applied: true, response: response)
    }

    /// Select `modelId`, through whichever control the agent advertises.
    /// Returns the response of the config-option request, or `nil` on the legacy
    /// `session/set_model` path (which carries no config options back).
    public static func setModel(
        connection: ACPAgentConnection,
        sessionId: SessionId,
        modelId: String,
        models: ModelSupport.ModelState?,
        agentCommand: String?
    ) async throws -> SetSessionConfigOptionResponse? {
        guard let models else {
            throw UnsupportedError(
                """
                Cannot set model "\(modelId)": the ACP session did not advertise a model \
                config option or legacy session/set_model support.
                """,
                reason: .missingCapability)
        }
        let resolved = try resolveModelId(modelId, models: models, agentCommand: agentCommand)
        guard let configId = models.configId else {
            try await SessionControlError.wrappingModel("session/set_model", modelId: resolved) {
                try await connection.setModel(SetSessionModelRequest(sessionId: sessionId, modelId: resolved))
            }
            return nil
        }
        return try await SessionControlError.wrappingModel("session/set_config_option", modelId: resolved) {
            try await connection.setConfigOption(
                SetSessionConfigOptionRequest(sessionId: sessionId, configId: configId, value: resolved))
        }
    }

    /// Set one config option. A value going to the *model's* option is resolved
    /// as a model id first, so `--config-option model=<alias>` is validated the
    /// same way `--model <alias>` is rather than reaching the agent unchecked.
    public static func setConfigOption(
        connection: ACPAgentConnection,
        sessionId: SessionId,
        configId: String,
        value: String,
        models: ModelSupport.ModelState?,
        agentCommand: String?
    ) async throws -> SetSessionConfigOptionResponse {
        var resolved = value
        if let models, models.configId == configId {
            resolved = try resolveModelId(value, models: models, agentCommand: agentCommand)
        }
        return try await SessionControlError.wrapping(
            "session/set_config_option", context: "for \"\(configId)\"=\"\(value)\"") {
            try await connection.setConfigOption(
                SetSessionConfigOptionRequest(sessionId: sessionId, configId: configId, value: resolved))
        }
    }

    // MARK: - Advertised state

    /// Fold a response's config options into the model state tracked across a
    /// turn's setup, so a later option resolves against what the agent last
    /// advertised. A response that derives no model state clears it, unless the
    /// state came from legacy `models` metadata — which config options never
    /// carried and so can't have withdrawn.
    public static func advance(
        _ state: ModelSupport.ModelState?, with configOptions: [JSONValue]?
    ) -> ModelSupport.ModelState? {
        if let derived = ModelSupport.modelState(fromConfigOptions: configOptions) { return derived }
        return state?.configId == nil ? state : nil
    }

    // MARK: - Validation

    /// Check a requested model against what the agent advertised: returns a
    /// warning to surface (the request still goes out), `nil` when it's plainly
    /// supported, and throws when it can't be applied at all.
    @discardableResult
    public static func assertRequestedModelSupported(
        requestedModel: String,
        models: ModelSupport.ModelState?,
        agentCommand: String?,
        context: Context
    ) throws -> String? {
        guard let models else {
            if supportsLegacyClaudeCodeModelMetadata(agentCommand) { return nil }
            throw UnsupportedError(
                """
                Cannot \(context.action) "\(requestedModel)": the ACP agent did not advertise \
                model support through a session config option or legacy models metadata, and the \
                adapter does not support a startup model flag.
                """,
                reason: .missingCapability)
        }
        guard !models.availableModels.contains(where: { $0.modelId == requestedModel }) else {
            return nil
        }
        let resolved = try resolveRequestedModelId(
            requestedModel, models: models, agentCommand: agentCommand)
        if resolved != requestedModel {
            return """
                Cursor ACP advertised "\(resolved)" for requested model "\(requestedModel)"; \
                using the advertised id.
                """
        }
        if supportsLegacyClaudeCodeModelMetadata(agentCommand) {
            return """
                requested model "\(requestedModel)" was not in the Claude ACP advertised model \
                list (\(formatAvailableModelIds(models))); forwarding it to Claude Code so the \
                adapter can accept or reject it.
                """
        }
        throw UnsupportedError(
            """
            Cannot \(context.action) "\(requestedModel)": the ACP agent did not advertise that \
            model. Available models: \(formatAvailableModelIds(models)).
            """,
            reason: .unadvertisedModel)
    }

    /// Validate, then resolve — the pair every outgoing model value goes through.
    private static func resolveModelId(
        _ modelId: String, models: ModelSupport.ModelState, agentCommand: String?
    ) throws -> String {
        try assertRequestedModelSupported(
            requestedModel: modelId, models: models, agentCommand: agentCommand, context: .apply)
        return try resolveRequestedModelId(modelId, models: models, agentCommand: agentCommand)
    }

    /// Cursor advertises its models with a suffix (`gpt-5[thinking]`), so a bare
    /// id is treated as an alias for the single advertised model that starts with
    /// it. Every other adapter gets the requested id back unchanged.
    public static func resolveRequestedModelId(
        _ requestedModel: String, models: ModelSupport.ModelState?, agentCommand: String?
    ) throws -> String {
        guard let models, isCursorAcpCommandForModelAlias(agentCommand) else { return requestedModel }
        guard !models.availableModels.contains(where: { $0.modelId == requestedModel }) else {
            return requestedModel
        }
        let candidates = models.availableModels.map(\.modelId)
            .filter { $0.hasPrefix("\(requestedModel)[") }
        guard candidates.count <= 1 else {
            throw UnsupportedError(
                """
                Cannot select model "\(requestedModel)": multiple advertised Cursor models match \
                (\(candidates.joined(separator: ", "))). Use an exact advertised model ID.
                """,
                reason: .unadvertisedModel, ambiguous: true)
        }
        return candidates.first ?? requestedModel
    }

    /// acpx's `formatAvailableModelIds`: a comma-separated list, or the literal
    /// `none advertised` when the agent offered none.
    public static func formatAvailableModelIds(_ models: ModelSupport.ModelState?) -> String {
        let ids = (models?.availableModels ?? [])
            .map { $0.modelId.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ids.isEmpty ? "none advertised" : ids.joined(separator: ", ")
    }

    // MARK: - Adapter shapes (acpx `acp/agent-command.ts`)

    /// Claude Code takes a model the ACP layer never advertised, so an
    /// unadvertised id is forwarded to it rather than refused here.
    static func supportsLegacyClaudeCodeModelMetadata(_ agentCommand: String?) -> Bool {
        guard let (command, args) = commandShape(agentCommand) else { return false }
        if basenameToken(command) == "claude-agent-acp" { return true }
        return args.contains { $0.contains("claude-agent-acp") }
    }

    static func isCursorAcpCommandForModelAlias(_ agentCommand: String?) -> Bool {
        guard let (command, args) = commandShape(agentCommand) else { return false }
        let token = basenameToken(command)
        return token == "cursor-agent" || (token == "agent" && args.contains("acp"))
    }

    private static func commandShape(_ agentCommand: String?) -> (String, [String])? {
        guard let agentCommand, !agentCommand.isEmpty else { return nil }
        let tokens = AgentRegistry.splitCommandLine(agentCommand)
        guard let command = tokens.first else { return nil }
        return (command, Array(tokens.dropFirst()))
    }

    /// acpx's `basenameToken`: the lowercased file name with a Windows
    /// executable suffix dropped. Node's `path.basename` is platform-dependent,
    /// so a backslash only separates on Windows.
    static func basenameToken(_ value: String) -> String {
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
}
