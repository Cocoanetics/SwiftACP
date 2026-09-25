import Foundation
import JSONFoundation
import SwiftACP

/// A saved selection a reconnect could not put back — acpx's `SessionModeReplayError`,
/// `SessionModelReplayError` and `SessionConfigOptionReplayError`. The turn or control
/// that connected fails, as a runtime failure worth retrying, and the record stays as
/// it was.
public struct SessionReplayError: LocalizedError, OutputErrorMeta, Sendable {
    /// Which selection failed.
    public enum Selection: Sendable {
        case mode, model, configOption
    }

    public let selection: Selection
    public let message: String

    public init(_ selection: Selection, _ message: String) {
        self.selection = selection
        self.message = message
    }

    public var errorDescription: String? { message }
    public var outputCode: String? { "RUNTIME" }
    public var detailCode: String? {
        switch selection {
        case .mode: "SESSION_MODE_REPLAY_FAILED"
        case .model: "SESSION_MODEL_REPLAY_FAILED"
        case .configOption: "SESSION_CONFIG_OPTION_REPLAY_FAILED"
        }
    }
    public var origin: String? { "acp" }
    public var retryable: Bool? { true }
}

/// Putting a session's saved selections back once it is connected again — acpx
/// 0.19.1's `replaySessionPreferences` and the record bookkeeping around it in
/// `connectAndLoadSession`.
///
/// - A session the agent still held is not replayed at all.
/// - The mode goes first, and only onto a fresh session: a loaded one kept its own.
/// - Then the pinned model, `session_options.model`, through the control the session
///   advertises — even unchanged, since its reply reconciles the other options. A
///   session that advertises no models is not asked, unless it is fresh.
/// - Then each saved option, but for one the last reply no longer accepts.
///
/// Each acknowledgement is recorded as it comes. A failure ends the replay with a
/// ``SessionReplayError``; the caller then keeps the record as it was.
public enum ReconnectReplay {
    /// What the control connecting the session is about to change, which is therefore
    /// not put back first — acpx's `replacingMode` and `replacingConfigOption`.
    public enum Replacing: Sendable, Equatable {
        case mode
        case configOption(String)
    }

    /// The selections to put back, read from the record before connecting, as acpx
    /// reads them at the start of `connectAndLoadSession`.
    public struct Desired: Sendable {
        public var modeId: String?
        public var modelId: String?
        /// In the order they are sent: the order the record holds them in, as acpx's
        /// reconnect iterates its object (`Object.entries`).
        public var configOptions: [(id: String, value: String)]

        /// What to put back of `record`, saved options in the record's order.
        public init(_ record: SessionRecord?, replacing: Replacing?) {
            self.init(record?.acpx, replacing: replacing, order: record?.savedConfigOptionOrder ?? [])
        }

        /// What to put back of `state`: saved options in `order`, and any it leaves out
        /// after them, by id.
        public init(_ state: SessionAcpxState?, replacing: Replacing?, order: [String] = []) {
            modeId = replacing == .mode ? nil : Self.normalized(state?.desiredModeId)
            let pinned = Self.normalized(state?.sessionOptions?.model)
            var options = state?.desiredConfigOptions ?? [:]
            // A record an earlier SwiftACP wrote can keep a `set model` as the model's
            // saved option — `set model` did not pin then, and acpx never writes one. It is
            // the newer choice even beside a pin: it is put back as the model, which pins
            // it, as `set model` records it now — not again as an option.
            if let modelConfigId = Self.modelConfigId(state), let later = options.removeValue(forKey: modelConfigId) {
                modelId = Self.normalized(later) ?? pinned
            } else {
                modelId = pinned
            }
            let ordered = order.filter { options[$0] != nil }
            let unordered = options.keys.filter { !ordered.contains($0) }.sorted()
            configOptions = WireJSON.propertyOrder(ordered + unordered)
                .compactMap { id in options[id].map { (id, $0) } }
        }

        private static func normalized(_ value: String?) -> String? {
            guard let trimmed = value?.javaScriptTrimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }

        private static func modelConfigId(_ state: SessionAcpxState?) -> String? {
            guard case .array(let options)? = state?.configOptions else { return nil }
            return ModelSupport.modelState(fromConfigOptions: options)?.configId
        }
    }

    /// How the session came back — acpx's `RuntimeSessionLoadState`.
    public struct Loaded: Sendable {
        public var sessionId: String
        /// Whether a `session/new` started it, rather than a load or resume.
        public var createdFreshSession: Bool
        public var configOptions: [JSONValue]?
        public var models: ModelSupport.ModelState?
        public var legacyModelMetadataPresent: Bool

        public init(sessionId: String, createdFreshSession: Bool, configOptions: [JSONValue]?, models: JSONValue?) {
            self.sessionId = sessionId
            self.createdFreshSession = createdFreshSession
            self.configOptions = configOptions
            self.models = ModelSupport.modelState(fromConfigOptions: configOptions)
                ?? ModelSupport.modelState(fromLegacyModels: models)
            legacyModelMetadataPresent = models != nil
        }

        public var configOptionsPresent: Bool { configOptions != nil }
    }

    /// What the replay left the session advertising, for the record after it.
    public struct Outcome: Sendable {
        public var models: ModelSupport.ModelState?
        public var configOptionsPresent: Bool
    }

    /// What the session's own reply says of the record, before anything is replayed —
    /// acpx's `applyConfigOptionsToRecord` and `applyReconnectedModelState`.
    public static func applyLoaded(_ loaded: Loaded, to state: inout SessionAcpxState?) {
        if let configOptions = loaded.configOptions {
            // On the block built anew — a clone, or a new block when there was none.
            var acpx = state?.cloned() ?? SessionAcpxState()
            ModelSupport.applyConfigOptionsModelState(configOptions, to: &acpx)
            state = acpx
        }
        applyReconnectedModelState(
            loaded.models, configOptionsPresent: loaded.configOptionsPresent,
            legacyModelMetadataPresent: loaded.legacyModelMetadataPresent,
            createdFreshSession: loaded.createdFreshSession, to: &state)
    }

    /// acpx's `applyReconnectedModelState`: a fresh session that reported no options
    /// has none; a legacy model list with no model option drops the model's options;
    /// no models at all clears the advertised model state, unless a loaded session
    /// merely left them out.
    public static func applyReconnectedModelState(
        _ models: ModelSupport.ModelState?, configOptionsPresent: Bool, legacyModelMetadataPresent: Bool,
        createdFreshSession: Bool, to state: inout SessionAcpxState?
    ) {
        if createdFreshSession, !configOptionsPresent, state != nil {
            state?.configOptions = nil
            state?.forget("config_options")
        }
        guard let models else {
            if legacyModelMetadataPresent || createdFreshSession, var acpx = state {
                ModelSupport.clearAdvertisedModelState(&acpx)
                state = acpx
            }
            return
        }
        var acpx = state ?? SessionAcpxState()
        if legacyModelMetadataPresent, models.configId == nil, case .array(let options)? = acpx.configOptions {
            acpx.configOptions = .array(options.filter { option in
                guard case .object(let fields) = option else { return true }
                return fields["category"] != .string("model") && fields["id"] != .string("model")
            })
        }
        ModelSupport.applyAdvertisedModelState(models, to: &acpx)
        state = acpx
    }

    /// Put `desired` back on the session `loaded` describes, recording each
    /// acknowledgement in `state`. `original` is the record's state before connecting,
    /// whose model option a control replacing the model may name.
    ///
    /// - Throws: ``SessionReplayError`` for the first selection that failed.
    public static func replay(
        _ desired: Desired, replacing: Replacing?, original: SessionAcpxState?, loaded: Loaded,
        state: inout SessionAcpxState?, connection: ACPAgentConnection, agentCommand: String,
        onWarning: ((String) -> Void)? = nil
    ) async throws -> Outcome {
        let target = Target(connection: connection, sessionId: loaded.sessionId, agentCommand: agentCommand)
        let mode = loaded.createdFreshSession ? try await replayMode(desired.modeId, state: state, on: target) : nil
        let models = mode.map(\.models) ?? loaded.models

        var replacingKey: String?
        if case .configOption(let key)? = replacing { replacingKey = key }
        let replacesModel = replacingKey.map { key in
            key == "model" || key == models?.configId || key == ModelSupport.advertisedModelState(original)?.configId
        } ?? false

        var model: ModelReplay?
        if !replacesModel, let modelId = desired.modelId, loaded.createdFreshSession || models != nil {
            model = try await replayModel(modelId, models: models, state: &state, on: target, onWarning: onWarning)
        }
        let options = try await replayOptions(
            replacesModel ? [] : desired.configOptions, skipping: replacingKey, accepted: model?.options,
            state: &state, on: target)

        // acpx's `resolveModelsAfterReplay` and `resolveConfigOptionsPresenceAfterReplay`.
        let afterModel = model.map(\.models) ?? models
        let legacyAfterModel = afterModel.flatMap { $0.configId == nil ? $0 : nil }
        let finalModels = options.map { $0.models ?? legacyAfterModel } ?? afterModel
        let optionsPresent = loaded.configOptionsPresent || mode?.configOptionsPresent == true || options != nil
            || model?.options != nil
        return Outcome(models: finalModels, configOptionsPresent: optionsPresent)
    }

    /// Where the replay goes.
    private struct Target {
        let connection: ACPAgentConnection
        let sessionId: String
        let agentCommand: String
    }

    /// What replaying the mode left: acpx's `modeMetadata`.
    private struct ModeReplay {
        let models: ModelSupport.ModelState?
        let configOptionsPresent: Bool
    }

    /// What replaying the model left: acpx's `ModelReplayResult`.
    private struct ModelReplay {
        let models: ModelSupport.ModelState?
        /// The options the agent's reply reported, when it replied with any.
        let options: [JSONValue]?
    }

    /// What replaying the options left: acpx's `ConfigReplayResult`.
    private struct OptionsReplay {
        let models: ModelSupport.ModelState?
    }

    /// acpx's `replayDesiredMode`, for a fresh session.
    private static func replayMode(
        _ modeId: String?, state: SessionAcpxState?, on target: Target
    ) async throws -> ModeReplay? {
        guard let modeId else { return nil }
        do {
            try await target.connection.setMode(SetSessionModeRequest(sessionId: target.sessionId, modeId: modeId))
        } catch {
            throw SessionReplayError(.mode, """
                Failed to replay saved session mode \(modeId) on fresh ACP session \(target.sessionId): \
                \(TurnFailure.message(of: error))
                """)
        }
        return ModeReplay(
            models: ModelSupport.advertisedModelState(state), configOptionsPresent: state?.configOptions != nil)
    }

    /// acpx's `replayDesiredModel`: checked against what the session advertises, then
    /// sent even unchanged; not sent to a session advertising no models.
    private static func replayModel(
        _ modelId: String, models: ModelSupport.ModelState?, state: inout SessionAcpxState?, on target: Target,
        onWarning: ((String) -> Void)?
    ) async throws -> ModelReplay? {
        do {
            if let warning = try ModelApplication.assertRequestedModelSupported(
                requestedModel: modelId, models: models, agentCommand: target.agentCommand, context: .replay) {
                onWarning?(warning)
            }
            guard let models else { return nil }
            let response = try await ModelApplication.setModel(
                connection: target.connection, sessionId: target.sessionId, modelId: modelId, models: models,
                agentCommand: target.agentCommand)
            var acpx = state ?? SessionAcpxState()
            ModelSupport.applyModelSelection(modelId, response: response, to: &acpx)
            state = acpx
            guard let response else {
                var current = models
                current.currentModelId = modelId
                return ModelReplay(models: current, options: nil)
            }
            return ModelReplay(
                models: ModelSupport.modelState(fromConfigOptions: response.configOptions),
                options: response.configOptions)
        } catch {
            throw SessionReplayError(.model, """
                Failed to replay saved session model \(modelId) on ACP session \(target.sessionId): \
                \(TurnFailure.message(of: error))
                """)
        }
    }

    /// acpx's `replayDesiredConfigOptions`: each saved option in turn, but for the one
    /// being replaced and one the last reply no longer accepts.
    private static func replayOptions(
        _ options: [(id: String, value: String)], skipping replacingKey: String?, accepted: [JSONValue]?,
        state: inout SessionAcpxState?, on target: Target
    ) async throws -> OptionsReplay? {
        var accepted = accepted
        var replayed: OptionsReplay?
        for (configId, value) in options {
            // Each reply can retire a later selection; what the session started with
            // does not.
            if configId == replacingKey { continue }
            if let accepted, !acceptsSavedValue(value, of: configId, in: accepted) { continue }
            do {
                let response = try await ModelApplication.setConfigOption(
                    connection: target.connection, sessionId: target.sessionId, configId: configId, value: value,
                    models: ModelSupport.advertisedModelState(state), agentCommand: target.agentCommand)
                var acpx = state ?? SessionAcpxState()
                ModelSupport.applyConfigOptionSelection(configId, value: value, response: response, to: &acpx)
                state = acpx
                accepted = response.configOptions
                replayed = OptionsReplay(models: ModelSupport.modelState(fromConfigOptions: response.configOptions))
            } catch {
                throw SessionReplayError(.configOption, """
                    Failed to replay saved session config option \(configId) on ACP session \(target.sessionId): \
                    \(TurnFailure.message(of: error))
                    """)
            }
        }
        return replayed
    }

    /// acpx's `acceptsSavedConfigValue`: a select option still offering `value`, as its
    /// current value or among its choices, grouped or not.
    static func acceptsSavedValue(_ value: String, of configId: String, in options: [JSONValue]) -> Bool {
        let option = options.first { option in
            if case .object(let fields) = option, case .string(let id)? = fields["id"] { return id == configId }
            return false
        }
        guard case .object(let fields)? = option, fields["type"] == .string("select") else { return false }
        if fields["currentValue"] == .string(value) { return true }
        guard case .array(let entries)? = fields["options"] else { return false }
        return entries.contains { entry in
            guard case .object(let entryFields) = entry else { return false }
            if case .array(let choices)? = entryFields["options"] {
                return choices.contains { choice in
                    if case .object(let choiceFields) = choice { return choiceFields["value"] == .string(value) }
                    return false
                }
            }
            return entryFields["value"] == .string(value)
        }
    }
}

extension SessionRecord {
    /// The ids of the saved config option selections, in the order the record holds
    /// them: as built since it was read (the order acpx gave the object), else as read.
    /// Ids it holds no order for are left out; the record writes them after the rest.
    var savedConfigOptionOrder: [String] {
        if let rebuilt = acpx?.rebuiltOrders["desired_config_options"] { return rebuilt }
        guard case .object(let members)? = parsedByAcpx?["acpx"]?["desired_config_options"] else { return [] }
        return members.map { String(decoding: $0.key, as: UTF16.self) }
    }
}
