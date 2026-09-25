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

    /// acpx's `applyConfigOptionsToRecord`: the config options a session reported, when
    /// it reported any, on the block built anew (a clone) — with the model state they carry.
    public static func applyConfigOptions(_ configOptions: [JSONValue]?, to state: inout SessionAcpxState) {
        guard let configOptions else { return }
        state = state.cloned()
        applyConfigOptionsModelState(configOptions, to: &state)
    }

    /// acpx's `applyAdvertisedModelState`: the session's current model, the models it
    /// offers and their names, and which control sets it.
    public static func applyAdvertisedModelState(_ models: ModelState, to state: inout SessionAcpxState) {
        state.currentModelId = models.currentModelId
        state.availableModels = models.availableModels.map(\.modelId)
        state.availableModelNames = Dictionary(
            models.availableModels.map { ($0.modelId, $0.name) }, uniquingKeysWith: { _, last in last })
        state.modelControl = models.configId != nil ? "config_option" : "legacy_set_model"
        state.rebuiltOrders["available_model_names"] = WireJSON.propertyOrder(models.availableModels.map(\.modelId))
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

    /// acpx's `applyModelSelection`: what selecting `modelId` leaves in the record — the
    /// options the agent reported back, with only the saved selections reconciled to
    /// them; the model pinned in `session_options`, and current; and no saved selection
    /// for the model's own option.
    public static func applyModelSelection(
        _ modelId: String, response: SetSessionConfigOptionResponse?, to state: inout SessionAcpxState
    ) {
        let modelConfigId = advertisedModelState(state)?.configId
        applyAcceptedConfigOptions(response, to: &state)
        if let modelConfigId { noteAccepted(modelConfigId, value: modelId, unreportedBy: response, in: &state) }
        var options = state.sessionOptions ?? SessionAcpxState.SessionOptions()
        options.model = modelId
        state.sessionOptions = options
        state.currentModelId = modelState(fromConfigOptions: response?.configOptions)?.currentModelId ?? modelId
        if let configId = modelConfigId ?? advertisedModelState(state)?.configId {
            state.desiredConfigOptions?.removeValue(forKey: configId)
            state.rebuiltOrders["desired_config_options"]?.removeAll { $0 == configId }
            if state.desiredConfigOptions?.isEmpty == true {
                state.desiredConfigOptions = nil
                state.forget("desired_config_options")
                state.rebuiltOrders["desired_config_options"] = nil
            }
        }
    }

    /// acpx's `applyConfigOptionSelection`: what setting option `configId` to `value`
    /// leaves in the record. The model's own option is a model selection — pinned, as
    /// ``applyModelSelection(_:response:to:)`` pins it; any other is saved as a
    /// selection to restore, with the options the agent reported back.
    public static func applyConfigOptionSelection(
        _ configId: String, value: String, response: SetSessionConfigOptionResponse,
        to state: inout SessionAcpxState
    ) {
        let modelConfigId = advertisedModelState(state)?.configId
        if configId == modelConfigId || configId == modelState(fromConfigOptions: response.configOptions)?.configId {
            applyModelSelection(value, response: response, to: &state)
            return
        }
        state = state.cloned()
        var desired = state.desiredConfigOptions ?? [:]
        desired[configId] = value
        state.desiredConfigOptions = desired
        if let order = state.rebuiltOrders["desired_config_options"] {
            state.rebuiltOrders["desired_config_options"] = WireJSON.propertyOrder(order + [configId])
        }
        applyAcceptedConfigOptions(response, to: &state)
        noteAccepted(configId, value: value, unreportedBy: response, in: &state)
    }

    /// A reply that does not report the options — `{}`, as SwiftACP's own agent bridge
    /// answers — leaves the record's as they were, but with the option just set at the
    /// value it was set to: the agent accepted it, as acpx takes the model a
    /// `session/set_model` reply leaves current to be the one asked for. Otherwise a
    /// later `--model` for the old value would be skipped as already current. (acpx
    /// reads the missing list as no options at all, clearing the model state with it,
    /// and fails outright on saved selections.)
    private static func noteAccepted(
        _ configId: String, value: String, unreportedBy response: SetSessionConfigOptionResponse?,
        in state: inout SessionAcpxState
    ) {
        guard response?.configOptions == nil, case .array(var options)? = state.configOptions else { return }
        for (index, option) in options.enumerated() {
            guard case .object(var fields) = option, case .string(let id)? = fields["id"], id == configId
            else { continue }
            fields["currentValue"] = .string(value)
            options[index] = .object(fields)
        }
        state.configOptions = .array(options)
    }

    /// acpx's `applyAcceptedConfigOptions`: the options a control's reply reported
    /// replace the record's, and saved selections follow what they now say — a reply
    /// can change sibling options — keeping only those still reported, in the order the
    /// reply lists them (`Object.fromEntries`).
    static func applyAcceptedConfigOptions(
        _ response: SetSessionConfigOptionResponse?, to state: inout SessionAcpxState
    ) {
        state = state.cloned()
        guard let reported = response?.configOptions else { return }
        applyConfigOptionsModelState(reported, to: &state)
        guard let desired = state.desiredConfigOptions else { return }
        var kept: [String: String] = [:]
        var order: [String] = []
        for case .object(let option) in reported {
            if case .string(let id)? = option["id"], case .string(let value)? = option["currentValue"],
               desired[id] != nil {
                kept[id] = value
                order.append(id)
            }
        }
        state.desiredConfigOptions = kept.isEmpty ? nil : kept
        if kept.isEmpty { state.forget("desired_config_options") }
        state.rebuiltOrders["desired_config_options"] = kept.isEmpty ? nil : WireJSON.propertyOrder(order)
    }

    /// acpx's `clearAdvertisedModelState`, which deletes the members.
    static func clearAdvertisedModelState(_ state: inout SessionAcpxState) {
        state.currentModelId = nil
        state.availableModels = nil
        state.availableModelNames = nil
        state.rebuiltOrders["available_model_names"] = nil
        state.modelControl = nil
        for key in ["current_model_id", "available_models", "available_model_names", "model_control"] {
            state.forget(key)
        }
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
        applyConfigOptions(replied, to: &state)
        if let models = application.response != nil ? modelState(fromConfigOptions: replied) : originalModels {
            applyAdvertisedModelState(models, to: &state)
        }
        guard application.applied else { return }
        let current = modelState(fromConfigOptions: replied)?.currentModelId ?? requestedModel
        state.currentModelId = current.flatMap { $0.javaScriptTrimmed.isEmpty ? nil : $0.javaScriptTrimmed }
        // acpx's `setCurrentModelId` deletes the member for a blank model.
        if state.currentModelId == nil { state.forget("current_model_id") }
    }
}
