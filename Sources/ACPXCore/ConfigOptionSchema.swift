import Foundation
import JSONFoundation

/// A `config_option_update`'s options as acpx's ACP SDK reads them before acpx sees them
/// (`zConfigOptionUpdate`, `zSessionConfigOption`). A reply's options are not read this way:
/// acpx records those as the agent sent them.
public enum ConfigOptionSchema {
    /// The options `update` gives acpx, or `nil` when the SDK refuses the update for giving
    /// none. A `configOptions` that is no list reads as no options. An option that doesn't
    /// fit the schema is left out, and the others lose the members the schema doesn't know.
    public static func options(of update: JSONValue) -> JSONValue? {
        guard case .object(let members) = update, let reported = members["configOptions"] else { return nil }
        guard case .array(let options) = reported else { return .array([]) }
        return .array(options.compactMap(option))
    }

    /// Whether the SDK refuses `update` outright, for giving no `configOptions`.
    public static func refuses(_ update: JSONValue) -> Bool {
        guard case .object(let members) = update else { return true }
        return !members.keys.contains("configOptions")
    }

    /// `zSessionConfigOption`: a select or a boolean, with an id and a name.
    static func option(_ value: JSONValue) -> JSONValue? {
        guard case .object(let raw) = value, case .string(let id)? = raw["id"], case .string(let name)? = raw["name"],
              var parsed = select(raw) ?? boolean(raw)
        else { return nil }
        parsed["id"] = .string(id)
        parsed["name"] = .string(name)
        parsed["description"] = nullableString(raw["description"])
        parsed["category"] = nullableString(raw["category"])
        parsed["_meta"] = meta(raw["_meta"])
        return .object(parsed)
    }

    /// `zSessionConfigSelect`, with `type: "select"`.
    private static func select(_ raw: [String: JSONValue]) -> [String: JSONValue]? {
        guard raw["type"] == .string("select"), case .string(let current)? = raw["currentValue"],
              case .array(let entries)? = raw["options"], let options = selectOptions(entries)
        else { return nil }
        return ["currentValue": .string(current), "options": .array(options), "type": .string("select")]
    }

    /// `zSessionConfigBoolean`, with `type: "boolean"`.
    private static func boolean(_ raw: [String: JSONValue]) -> [String: JSONValue]? {
        guard raw["type"] == .string("boolean"), case .bool(let current)? = raw["currentValue"] else { return nil }
        return ["currentValue": .bool(current), "type": .string("boolean")]
    }

    /// `zSessionConfigSelectOptions`: every entry an option, or else every entry a group.
    /// One entry that is neither fails the whole list.
    private static func selectOptions(_ entries: [JSONValue]) -> [JSONValue]? {
        every(entries, selectOption) ?? every(entries, selectGroup)
    }

    /// `zSessionConfigSelectOption`.
    private static func selectOption(_ value: JSONValue) -> JSONValue? {
        guard case .object(let raw) = value, case .string(let id)? = raw["value"],
              case .string(let name)? = raw["name"]
        else { return nil }
        var parsed: [String: JSONValue] = ["value": .string(id), "name": .string(name)]
        parsed["description"] = nullableString(raw["description"])
        parsed["_meta"] = meta(raw["_meta"])
        return .object(parsed)
    }

    /// `zSessionConfigSelectGroup`: its options are required, empty when they are no list,
    /// and without the ones that don't fit.
    private static func selectGroup(_ value: JSONValue) -> JSONValue? {
        guard case .object(let raw) = value, case .string(let group)? = raw["group"],
              case .string(let name)? = raw["name"], let reported = raw["options"]
        else { return nil }
        var options: [JSONValue] = []
        if case .array(let entries) = reported { options = entries.compactMap(selectOption) }
        var parsed: [String: JSONValue] = ["group": .string(group), "name": .string(name), "options": .array(options)]
        parsed["_meta"] = meta(raw["_meta"])
        return .object(parsed)
    }

    /// Every entry parsed by `parse`, or `nil` when one does not parse.
    private static func every(_ entries: [JSONValue], _ parse: (JSONValue) -> JSONValue?) -> [JSONValue]? {
        var parsed: [JSONValue] = []
        for entry in entries {
            guard let value = parse(entry) else { return nil }
            parsed.append(value)
        }
        return parsed
    }

    /// A lenient nullable string (`defaultOnError(z.string().nullish(), …)`): a string or
    /// `null` as sent, anything else left out.
    private static func nullableString(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .string?, .null?: return value
        default: return JSONValue?.none
        }
    }

    /// A lenient `_meta` (`defaultOnError(z.record(…).nullish(), …)`): an object or `null`
    /// as sent, anything else left out.
    private static func meta(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .object?, .null?: return value
        default: return JSONValue?.none
        }
    }
}
