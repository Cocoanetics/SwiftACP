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
    public static func applySessionModelState(
        configOptions: [JSONValue]?, models: JSONValue?, to state: inout SessionAcpxState
    ) {
        if let configOptions {
            state.configOptions = .array(configOptions)
        }
        let derived =
            modelState(fromConfigOptions: configOptions) ?? modelState(fromLegacyModels: models)
        if let derivedModels = derived {
            let models = derivedModels
            state.currentModelId = models.currentModelId
            state.availableModels = models.availableModels.map(\.modelId)
            state.modelControl = models.configId != nil ? "config_option" : "legacy_set_model"
        }
    }
}
