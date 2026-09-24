import Foundation

// The `acpx` block of acpx's `parseSessionRecord` (`parseAcpxState`): rebuilt from the
// fields acpx knows, each kept only when valid — an invalid one is dropped, never the
// record. The order is the order acpx assigns them in.
//
// Split from `SessionRecordParser.swift` to keep each file inside the 500-line limit.
extension SessionRecordParser {
    /// `parseAcpxState`: `nil` when the block is not an object at all.
    static func acpxState(_ value: WireJSON?) -> WireJSON? {
        guard let value, case .object = value else { return nil }
        var state: [(String, WireJSON?)] = []
        if value["reset_on_next_ensure"] == .bool(true) { state.append(("reset_on_next_ensure", .bool(true))) }
        state.append(("current_mode_id", string(value["current_mode_id"])))
        state.append(("desired_mode_id", string(value["desired_mode_id"])))
        state.append(("desired_config_options", stringMap(value["desired_config_options"])))
        state.append(("available_model_names", stringMap(value["available_model_names"], preserveEmpty: true)))
        state += modelState(value)
        state.append(("available_commands", availableCommands(value["available_commands"])))
        state.append(("session_options", sessionOptions(value["session_options"])))
        return object(state)
    }

    /// `assignParsedModelState`. A `model_control` the block does not give is worked out
    /// from what it does — and, assigned last, lands after `config_options`.
    static func modelState(_ value: WireJSON) -> [(String, WireJSON?)] {
        let availableModels = stringArray(value["available_models"])
        var modelControl: WireJSON?
        if let given = value["model_control"], given == .text("config_option") || given == .text("legacy_set_model") {
            modelControl = given
        }
        var configOptions: WireJSON?
        if case .array(let options)? = value["config_options"], options.allSatisfy({ $0.isObject }) {
            configOptions = .array(options)
        }
        var state: [(String, WireJSON?)] = [
            ("current_model_id", string(value["current_model_id"])),
            ("available_models", availableModels),
            ("model_control", modelControl),
            ("config_options", configOptions)
        ]
        if modelControl == nil, availableModels != nil {
            let derived = hasModelConfigOption(configOptions) ? "config_option" : "legacy_set_model"
            state.append(("model_control", .text(derived)))
        }
        return state
    }

    /// `hasModelConfigOption`: an option in the `model` category, or with the id `model`.
    static func hasModelConfigOption(_ options: WireJSON?) -> Bool {
        guard case .array(let items)? = options else { return false }
        return items.contains { $0["category"] == .text("model") || $0["id"] == .text("model") }
    }

    /// `parseAvailableCommands`: each command acpx can read, left out when none is.
    static func availableCommands(_ value: WireJSON?) -> WireJSON? {
        guard case .array(let items)? = value else { return nil }
        let commands = items.compactMap(availableCommand)
        return commands.isEmpty ? nil : .array(commands)
    }

    /// `parseAvailableCommand`: a name — trimmed, from a string or an object — with the
    /// object's trimmed description and its `has_input` flag.
    static func availableCommand(_ value: WireJSON) -> WireJSON? {
        if case .string = value {
            return nonEmptyString(value).map { object([("name", $0)]) }
        }
        guard case .object = value, let name = nonEmptyString(value["name"]) else { return nil }
        var hasInput: WireJSON?
        if case .bool? = value["has_input"] { hasInput = value["has_input"] }
        return object([
            ("name", name), ("description", nonEmptyString(value["description"])), ("has_input", hasInput)
        ])
    }

    /// `assignParsedSessionOptions`: the options acpx knows, left out when none is valid.
    static func sessionOptions(_ value: WireJSON?) -> WireJSON? {
        guard let value, case .object = value else { return nil }
        var maxTurns: WireJSON?
        if let turns = value["max_turns"], isPositiveInteger(turns) { maxTurns = turns }
        let options: [(String, WireJSON?)] = [
            ("model", string(value["model"])),
            ("allowed_tools", stringArray(value["allowed_tools"])),
            ("max_turns", maxTurns),
            ("system_prompt", systemPrompt(value["system_prompt"])),
            ("env", stringMap(value["env"]))
        ]
        return options.contains { $0.1 != nil } ? object(options) : nil
    }

    /// `assignSessionOptionSystemPrompt`: a non-empty string, or `{ append }` with one.
    static func systemPrompt(_ value: WireJSON?) -> WireJSON? {
        if case .string(let units)? = value, !units.isEmpty { return value }
        guard let value, case .object = value, case .string(let append)? = value["append"], !append.isEmpty else {
            return nil
        }
        return object([("append", .string(append))])
    }

    // MARK: - Helpers

    /// A string field, dropped when it is anything else.
    static func string(_ value: WireJSON?) -> WireJSON? {
        guard case .string? = value else { return nil }
        return value
    }

    /// `isStringArray`, copied as acpx copies it.
    static func stringArray(_ value: WireJSON?) -> WireJSON? {
        guard case .array(let items)? = value, items.allSatisfy({ $0.stringValue != nil }) else { return nil }
        return .array(items)
    }

    /// `parseStringMap`: the members whose values are strings, left out when there are
    /// none unless `preserveEmpty`.
    static func stringMap(_ value: WireJSON?, preserveEmpty: Bool = false) -> WireJSON? {
        guard case .object(let members)? = value else { return nil }
        let strings = members.filter { $0.value.stringValue != nil }
        return strings.isEmpty && !preserveEmpty ? nil : .object(strings)
    }
}
