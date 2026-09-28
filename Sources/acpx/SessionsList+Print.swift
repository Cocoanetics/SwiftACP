import ACPXCore
import Foundation
import SwiftACP

// How acpx prints the agent's sessions (`printAgentSessionsByFormat`): its answer as it is, with
// JavaScript's reading of it — a member missing is `undefined`, a value printed as a template
// literal prints it, and an answer of the wrong shape fails as the TypeError it raises there.
extension SessionsList {
    static func printAgentSessions(_ result: WireJSON, format: String) throws {
        switch format {
        case "json":
            Console.out(result.compact() + "\n")
        case "quiet":
            // `for (const session of result.sessions)`
            for session in try iterated(result["sessions"]) {
                Console.out(template(try property(session, "sessionId")) + "\n")
            }
        default:
            try printText(result)
        }
    }

    /// acpx's `printTextAgentSessions`: a line for each session — `No sessions` for none — and
    /// the cursor to go on from, when there is one.
    private static func printText(_ result: WireJSON) throws {
        let sessions = result["sessions"]
        if try length(of: sessions) == 0 {
            Console.out("No sessions\n")
        } else {
            for session in try iterated(sessions) {
                let title = try property(session, "title").orDash
                let updatedAt = try property(session, "updatedAt").orDash
                let meta = try property(session, "_meta")
                let metaText = truthy(meta) ? (meta?.compact() ?? "-") : "-"
                let columns = [
                    template(try property(session, "sessionId")), title, template(try property(session, "cwd")),
                    updatedAt, metaText
                ]
                Console.out(columns.joined(separator: "\t") + "\n")
            }
        }
        if let cursor = result["nextCursor"], truthy(cursor) {
            Console.out("Next cursor: \(template(cursor))\n")
        }
    }

    /// `sessions.length`: a list's or a string's (in UTF-16 units); `nil` — `undefined` — for
    /// another value, which then fails as it is iterated.
    private static func length(of sessions: WireJSON?) throws -> Int? {
        switch sessions {
        case nil: throw TypeError.reading("length", of: "undefined")
        case .null?: throw TypeError.reading("length", of: "null")
        case .array(let items)?: return items.count
        case .string(let units)?: return units.count
        default: return nil
        }
    }

    /// What `for…of` goes through: a list's items, or a string's characters, each a string.
    private static func iterated(_ sessions: WireJSON?) throws -> [WireJSON] {
        switch sessions {
        case .array(let items)?: return items
        case .string(let units)?:
            return String(decoding: units, as: UTF16.self).unicodeScalars.map { .text(String($0)) }
        default: throw TypeError(message: "result.sessions is not iterable")
        }
    }

    /// `session[name]`: a member of an object; `undefined` of any other value but `null`, which
    /// has no properties to read.
    private static func property(_ session: WireJSON, _ name: String) throws -> WireJSON? {
        switch session {
        case .null: throw TypeError.reading(name, of: "null")
        case .object: return session[name]
        default: return nil
        }
    }

    /// Whether `value` is truthy in JavaScript.
    private static func truthy(_ value: WireJSON?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0 && !number.isNaN
        case .string(let units)?: return !units.isEmpty
        case .array?, .object?: return true
        }
    }

    /// `${value}`: JavaScript's `String(value)`.
    static func template(_ value: WireJSON?) -> String {
        switch value {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool(let flag)?: return flag ? "true" : "false"
        case .number(let number)?: return WireJSON.javaScriptString(for: number)
        case .string(let units)?: return String(decoding: units, as: UTF16.self)
        // `Array.prototype.join(",")`, an item that is `null` or `undefined` empty.
        case .array(let items)?: return items.map { $0 == .null ? "" : template($0) }.joined(separator: ",")
        case .object?: return "[object Object]"
        }
    }

    /// The TypeError JavaScript raises where acpx's printing reads what is not there.
    struct TypeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }

        static func reading(_ property: String, of value: String) -> TypeError {
            TypeError(message: "Cannot read properties of \(value) (reading '\(property)')")
        }
    }
}

private extension Optional where Wrapped == WireJSON {
    /// `value ?? "-"`, printed.
    var orDash: String {
        switch self {
        case nil, .null?: return "-"
        default: return SessionsList.template(self)
        }
    }
}
