import Foundation
import JSONFoundation
import SwiftACP

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

    /// `options`, as ``options(of:)`` gave them, in the order the SDK builds them: an option's
    /// `currentValue`, `options` and `type` — its kind's members — then `id`, `name`,
    /// `description`, `category` and `_meta`; a select option's `value`, `name`, `description`,
    /// `_meta`; a group's `group`, `name`, `options`, `_meta` (zod's intersection of the kind and
    /// the rest, each object built in its shape's order). Each `_meta` — a zod record, which keeps
    /// what the agent wrote in its order — is in the order of its counterpart in `written`, the
    /// update's `configOptions` as they came (#243 review): an option matched by its `id`, a select
    /// option by its `value`, a group by its `group`, as ``inOrder(_:of:)`` matches them.
    public static func ordered(_ options: JSONValue, as written: WireJSON? = nil) -> WireJSON {
        guard case .array(let items) = options else { return WireJSON(options) }
        let candidates = entries(of: written)
        return .array(items.enumerated().map { index, item in
            schemaOrdered(item, optionOrder, as: counterpart(of: item, at: index, in: candidates, keys: ["id"]))
        })
    }

    /// The items of `list`, when it is one.
    private static func entries(of list: WireJSON?) -> [WireJSON] {
        if case .array(let items)? = list { return items }
        return []
    }

    /// `current`, the record's options, in the order of `template` — the order they came in. Each
    /// option takes its counterpart's order all the way down, `_meta` and all: an object's members
    /// in the counterpart's order, each like the counterpart's own, those it lacks after, sorted.
    /// An option's counterpart is the one with its `id`, a select option's the one with its
    /// `value`, a group's the one with its `group` — when exactly one has it — and otherwise the
    /// one in its place (#243 review). As acpx changes an option in place (a selection's
    /// `currentValue`), its members keep their places.
    public static func inOrder(_ current: JSONValue, of template: WireJSON) -> WireJSON {
        like(current, template, keys: ["id"])
    }

    private static let optionOrder = [
        "currentValue", "options", "type", "id", "name", "description", "category", "_meta"
    ]
    private static let selectOptionOrder = ["value", "name", "description", "_meta"]
    private static let groupOrder = ["group", "name", "options", "_meta"]

    /// `value`'s members in `order`, then any others sorted; an option's `options` entries each
    /// in their own shape's order; its `_meta` in the order of `written`'s, its counterpart as it
    /// came, all the way down.
    private static func schemaOrdered(_ value: JSONValue, _ order: [String], as written: WireJSON?) -> WireJSON {
        guard case .object(let members) = value else { return WireJSON(value) }
        let keys = order.filter { members[$0] != nil } + members.keys.filter { !order.contains($0) }.sorted()
        return .object(keys.map { key in
            let member = members[key] ?? .null
            if key == "_meta" { return WireJSON.Member(key, like(member, written?["_meta"], keys: [])) }
            guard key == "options", case .array(let entries) = member else {
                return WireJSON.Member(key, WireJSON(member))
            }
            let candidates = Self.entries(of: written?["options"])
            return WireJSON.Member(key, .array(entries.enumerated().map { index, entry in
                guard case .object(let fields) = entry else { return WireJSON(entry) }
                let counterpart = counterpart(of: entry, at: index, in: candidates, keys: ["value", "group"])
                return schemaOrdered(entry, fields["group"] != nil ? groupOrder : selectOptionOrder, as: counterpart)
            }))
        })
    }

    /// `value` in the order of `template`, its counterpart: an object's members in the
    /// counterpart's order, each like the counterpart's own, then those it lacks, sorted; an
    /// array's items each like the counterpart ``counterpart(of:at:in:keys:)`` finds for it by
    /// `keys`. An option's or a group's `options` are matched by `value` or `group`.
    private static func like(_ value: JSONValue, _ template: WireJSON?, keys: [String]) -> WireJSON {
        switch value {
        case .object(let members):
            var order: [String] = []
            if case .object(let fields)? = template {
                order = fields.map { String(decoding: $0.key, as: UTF16.self) }
            }
            let names = order.filter { members[$0] != nil } + members.keys.filter { !order.contains($0) }.sorted()
            return .object(names.map { name in
                let entries = name == "options" ? ["value", "group"] : []
                return WireJSON.Member(name, like(members[name] ?? .null, template?[name], keys: entries))
            })
        case .array(let items):
            var candidates: [WireJSON] = []
            if case .array(let list)? = template { candidates = list }
            return .array(items.enumerated().map { index, item in
                like(item, counterpart(of: item, at: index, in: candidates, keys: keys), keys: [])
            })
        default:
            return WireJSON(value)
        }
    }

    /// `item`'s counterpart among `candidates`, the items of its array's template: the one that
    /// shares its value under the first of `keys` it has, when exactly one does; none when none
    /// does — the entry is new; and otherwise the one at its `index`: an entry with no such
    /// member, or one that repeats another's, has only its place to go by.
    private static func counterpart(
        of item: JSONValue, at index: Int, in candidates: [WireJSON], keys: [String]
    ) -> WireJSON? {
        let atItsPlace = candidates.indices.contains(index) ? candidates[index] : nil
        guard case .object(let fields) = item,
            let key = keys.first(where: { if case .string? = fields[$0] { return true } else { return false } }),
            case .string(let wanted)? = fields[key]
        else { return atItsPlace }
        let sharing = candidates.filter { $0[key]?.stringValue == wanted }
        switch sharing.count {
        case 0: return nil
        case 1: return sharing[0]
        default: return atItsPlace?[key]?.stringValue == wanted ? atItsPlace : sharing[0]
        }
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
