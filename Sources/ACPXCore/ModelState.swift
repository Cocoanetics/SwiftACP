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

    /// acpx's `modelStateFromConfigOptions`: the model picker among the options a
    /// session reported — none when what it reported is no list.
    public static func modelState(fromConfigOptions options: JSONValue?) -> ModelState? {
        guard case .array(let options)? = options else { return nil }
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
    /// What it reported is taken as it is, but not when JavaScript reads it as false
    /// (`if (!configOptions) return`): `null`, `false`, `0` or `""`.
    public static func applyConfigOptions(_ configOptions: JSONValue?, to state: inout SessionAcpxState) {
        guard let configOptions, configOptions.isTruthyInJavaScript else { return }
        applyConfigOptionsToState(configOptions, to: &state)
    }

    /// acpx's `applyConfigOptionsToState`: the config options a session reported, whatever
    /// they are, on the block built anew (a clone) — with the model state they carry.
    public static func applyConfigOptionsToState(_ configOptions: JSONValue, to state: inout SessionAcpxState) {
        state = state.cloned()
        applyConfigOptionsModelState(configOptions, to: &state)
    }

    /// acpx's `normalizeResponseConfigOptions`: a reply's `configOptions` as acpx takes
    /// it — `null` as an empty list, anything else as it is, and none as none.
    public static func normalizedResponseConfigOptions(_ raw: JSONValue?) -> JSONValue? {
        raw == .null ? .array([]) : raw
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
        if let fromOptions = modelState(fromConfigOptions: state.configOptions) { return fromOptions }
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
        state.currentModelId = modelState(fromConfigOptions: response?.rawConfigOptions)?.currentModelId ?? modelId
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
        if configId == modelConfigId || configId == modelState(fromConfigOptions: response.rawConfigOptions)?.configId {
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
    /// answers — is an acknowledgement, not a withdrawal of the catalog, as acpx 0.19.3
    /// takes it (`applyAcceptedConfigOptions`, #778): the record's options stay, the
    /// first with the option's id at the value it was set to. Otherwise a later `--model`
    /// for the old value would be skipped as already current.
    private static func noteAccepted(
        _ configId: String, value: String, unreportedBy response: SetSessionConfigOptionResponse?,
        in state: inout SessionAcpxState
    ) {
        guard response?.rawConfigOptions == nil, case .array(var options)? = state.configOptions else { return }
        for (index, option) in options.enumerated() {
            guard case .object(var fields) = option, case .string(let id)? = fields["id"], id == configId
            else { continue }
            fields["currentValue"] = .string(value)
            options[index] = .object(fields)
            break
        }
        state.configOptions = .array(options)
    }

    /// acpx's `applyAcceptedConfigOptions`: the options a control's reply reported
    /// replace the record's, and saved selections follow what they now say — a reply
    /// can change sibling options — keeping only those still reported, in the order the
    /// reply lists them (`Object.fromEntries`).
    ///
    /// Only a list reports any selections. acpx walks a string reply's characters, which
    /// report none; any other reply that is no list fails it with a `TypeError`
    /// (`configOptions is not iterable`), and reports none here.
    static func applyAcceptedConfigOptions(
        _ response: SetSessionConfigOptionResponse?, to state: inout SessionAcpxState
    ) {
        state = state.cloned()
        guard let reported = response?.rawConfigOptions else { return }
        applyConfigOptionsModelState(reported, to: &state)
        guard let desired = state.desiredConfigOptions else { return }
        var kept: [String: String] = [:]
        var order: [String] = []
        for case .object(let option) in reported.arrayValue ?? [] {
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
    /// replace the record's, as it reported them, with the model state they carry. When
    /// they carry none — what it reported is no list, say — a legacy model control is
    /// kept, and any other model state is cleared.
    public static func applyConfigOptionsModelState(_ configOptions: JSONValue, to state: inout SessionAcpxState) {
        let preservesLegacyControl = state.modelControl == "legacy_set_model"
            || (state.modelControl == nil && modelState(fromConfigOptions: state.configOptions) == nil
                && state.availableModels != nil)
        state.configOptions = configOptions
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
    /// options the agent's reply reported, when it reported any, else from what
    /// `session/new` advertised; a model that was applied is selected, as
    /// ``applyModelSelection(_:response:to:)`` selects one — a reply reporting no
    /// options acknowledges it (acpx 0.19.3, #778).
    public static func applyInitialModelSelection(
        _ application: ModelApplication.Application, originalModels: ModelState?, to state: inout SessionAcpxState
    ) {
        let replied = application.response?.rawConfigOptions
        applyConfigOptions(replied, to: &state)
        if let models = replied != nil ? modelState(fromConfigOptions: replied) : originalModels {
            applyAdvertisedModelState(models, to: &state)
        }
        guard application.applied, let modelId = application.modelId else { return }
        applyModelSelection(modelId, response: application.response, to: &state)
    }
}

extension JSONValue {
    /// Whether JavaScript reads the value as true: everything but `null`, `false`, `0`
    /// and `""`.
    var isTruthyInJavaScript: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .integer(let value): return value != 0
        case .unsignedInteger(let value): return value != 0
        case .double(let value): return value != 0 && !value.isNaN
        case .string(let value): return !value.isEmpty
        case .array, .object: return true
        }
    }
}
