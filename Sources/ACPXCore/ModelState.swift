import Foundation
import JSONFoundation

/// Derives session model state from ACP `session/new` config options, ported
/// from acpx `acp/model-support.ts` + `session/model-state.ts`.
public enum ModelSupport {
    public struct ModelState: Sendable {
        public var configId: String?
        public var currentModelId: String
        public var availableModels: [(modelId: String, name: String)]
    }

    public static func modelState(fromConfigOptions options: [JSONValue]?) -> ModelState? {
        guard let options else { return nil }
        for value in options {
            if let state = parseModelConfigOption(value) { return state }
        }
        return nil
    }

    private static func parseModelConfigOption(_ value: JSONValue) -> ModelState? {
        guard case .object(let option) = value else { return nil }
        guard isModelSelectOption(option),
            case .string(let id)? = option["id"],
            case .string(let currentValue)? = option["currentValue"]
        else { return nil }
        guard let available = parseAvailableModels(option["options"]) else { return nil }
        return ModelState(configId: id, currentModelId: currentValue, availableModels: available)
    }

    /// Picks out the agent's model picker among generic config options: a `select`
    /// whose `category` is `model`, or — for agents without categories — whose `id`
    /// itself is `model`.
    private static func isModelSelectOption(_ option: [String: JSONValue]) -> Bool {
        guard case .string("select")? = option["type"] else { return false }
        if case .string("model")? = option["category"] { return true }
        if case .string("model")? = option["id"] { return true }
        return false
    }

    private static func parseAvailableModels(_ value: JSONValue?) -> [(modelId: String, name: String)]? {
        guard case .array(let array)? = value else { return nil }
        let direct = array.map(parseAvailableModel)
        if direct.allSatisfy({ $0 != nil }) { return direct.compactMap(\.self) }
        let grouped = array.map(parseAvailableModelGroup)
        if grouped.allSatisfy({ $0 != nil }) { return grouped.compactMap(\.self).flatMap(\.self) }
        return nil
    }

    private static func parseAvailableModel(_ value: JSONValue) -> (modelId: String, name: String)? {
        guard case .object(let obj) = value,
            case .string(let v)? = obj["value"], case .string(let n)? = obj["name"]
        else { return nil }
        return (v, n)
    }

    private static func parseAvailableModelGroup(_ value: JSONValue) -> [(modelId: String, name: String)]? {
        guard case .object(let group) = value,
            case .string? = group["group"], case .string? = group["name"],
            case .array(let options)? = group["options"]
        else { return nil }
        let models = options.map(parseAvailableModel)
        return models.allSatisfy { $0 != nil } ? models.compactMap(\.self) : nil
    }

    /// Parse a legacy `{ currentModelId, availableModels }` model advertisement.
    public static func modelState(fromLegacyModels models: JSONValue?) -> ModelState? {
        guard case .object(let m)? = models,
            case .string(let current)? = m["currentModelId"],
            case .array(let available)? = m["availableModels"]
        else { return nil }
        let parsed: [(modelId: String, name: String)] = available.compactMap { entry in
            guard case .object(let e) = entry,
                case .string(let modelId)? = e["modelId"], case .string(let name)? = e["name"]
            else { return nil }
            return (modelId, name)
        }
        return ModelState(configId: nil, currentModelId: current, availableModels: parsed)
    }

    /// Apply config-option models, falling back to the legacy `models` field, into
    /// a record's `acpx` block (`session/new` response).
    /// A fresh session's advertised model state *replaces* the record's — acpx's
    /// `applyReconnectedModelState` for a created session: config options it did not
    /// report are dropped, a legacy model list with no model option drops the model
    /// options, and with no models at all the advertised model state is cleared.
    public static func applyFreshSessionModelState(
        configOptions: [JSONValue]?, models: JSONValue?, to state: inout SessionAcpxState
    ) {
        if configOptions == nil { state.configOptions = nil }
        applySessionModelState(configOptions: configOptions, models: models, to: &state)
        let derived = modelState(fromConfigOptions: configOptions) ?? modelState(fromLegacyModels: models)
        guard let derived else {
            clearAdvertisedModelState(&state)
            return
        }
        if models != nil, derived.configId == nil, case .array(let options)? = state.configOptions {
            state.configOptions = .array(options.filter { option in
                guard case .object(let fields) = option else { return true }
                return fields["category"] != .string("model") && fields["id"] != .string("model")
            })
        }
    }

    public static func applySessionModelState(
        configOptions: [JSONValue]?, models: JSONValue?, to state: inout SessionAcpxState
    ) {
        if let configOptions {
            state.configOptions = .array(configOptions)
        }
        let derived =
            modelState(fromConfigOptions: configOptions) ?? modelState(fromLegacyModels: models)
        if let derived { applyAdvertisedModelState(derived, to: &state) }
    }

    /// acpx's `applyAdvertisedModelState`: the session's current model, the models it
    /// offers and their names, and which control sets it.
    public static func applyAdvertisedModelState(_ models: ModelState, to state: inout SessionAcpxState) {
        state.currentModelId = models.currentModelId
        state.availableModels = models.availableModels.map(\.modelId)
        state.availableModelNames = Dictionary(
            models.availableModels.map { ($0.modelId, $0.name) }, uniquingKeysWith: { _, last in last })
        state.modelControl = models.configId != nil ? "config_option" : "legacy_set_model"
    }

    /// acpx's `advertisedModelState`: the model state a record's `acpx` block keeps —
    /// from its config options, else, unless those are what sets the model, from its
    /// legacy model list.
    public static func advertisedModelState(_ state: SessionAcpxState?) -> ModelState? {
        guard let state else { return nil }
        var options: [JSONValue]?
        if case .array(let configOptions)? = state.configOptions { options = configOptions }
        if let fromOptions = modelState(fromConfigOptions: options) { return fromOptions }
        guard state.modelControl != "config_option", let available = state.availableModels else { return nil }
        return ModelState(
            configId: nil, currentModelId: state.currentModelId ?? "",
            availableModels: available.map { ($0, state.availableModelNames?[$0] ?? $0) })
    }

    /// acpx's `clearAdvertisedModelState`.
    static func clearAdvertisedModelState(_ state: inout SessionAcpxState) {
        state.currentModelId = nil
        state.availableModels = nil
        state.availableModelNames = nil
        state.modelControl = nil
    }

    /// acpx's `applyConfigOptionsModelState`: the config options the agent reported
    /// replace the record's, with the model state they carry. When they carry none, a
    /// legacy model control is kept, and any other model state is cleared.
    public static func applyConfigOptionsModelState(_ configOptions: [JSONValue], to state: inout SessionAcpxState) {
        var previousOptions: [JSONValue]?
        if case .array(let options)? = state.configOptions { previousOptions = options }
        let preservesLegacyControl = state.modelControl == "legacy_set_model"
            || (state.modelControl == nil && modelState(fromConfigOptions: previousOptions) == nil
                && state.availableModels != nil)
        state.configOptions = .array(configOptions)
        if let models = modelState(fromConfigOptions: configOptions) {
            applyAdvertisedModelState(models, to: &state)
        } else if preservesLegacyControl {
            state.modelControl = "legacy_set_model"
        } else {
            clearAdvertisedModelState(&state)
        }
    }

    /// acpx's `applyInitialModelSelection`: what applying the requested model to a new
    /// session leaves in its record. The advertised model state is taken from the
    /// agent's reply to the model's config option when there was one, else from what
    /// `session/new` advertised; a model that was applied is the current one.
    public static func applyInitialModelSelection(
        _ application: ModelApplication.Application, requestedModel: String?, originalModels: ModelState?,
        to state: inout SessionAcpxState
    ) {
        let replied = application.response?.configOptions
        if let replied { applyConfigOptionsModelState(replied, to: &state) }
        if let models = application.response != nil ? modelState(fromConfigOptions: replied) : originalModels {
            applyAdvertisedModelState(models, to: &state)
        }
        guard application.applied else { return }
        let current = modelState(fromConfigOptions: replied)?.currentModelId ?? requestedModel
        state.currentModelId = current.flatMap { $0.javaScriptTrimmed.isEmpty ? nil : $0.javaScriptTrimmed }
    }
}

extension SessionRecord {
    /// Move the record to the session a reconnect started in place of the gone one —
    /// acpx's fresh-session fallback: `acpSessionId` becomes the new session's, and
    /// the model state it advertised replaces the old (see
    /// ``ModelSupport/applyFreshSessionModelState(configOptions:models:to:)``).
    /// `acpxRecordId` stays.
    public mutating func moveToReplacement(sessionId: String, configOptions: [JSONValue]?, models: JSONValue?) {
        acpSessionId = sessionId
        var state = acpx ?? SessionAcpxState()
        ModelSupport.applyFreshSessionModelState(configOptions: configOptions, models: models, to: &state)
        acpx = state
    }
}
