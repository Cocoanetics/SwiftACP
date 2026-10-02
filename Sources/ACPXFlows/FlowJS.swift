import ACPXCore
import Foundation
import SwiftACP

/// The flow's own JavaScript values in a shell command's spec, where JSON cannot carry
/// them. acpx's runner holds the flow's values, and converts or writes them itself; the
/// host marks what JSON would lose (`encodeExecution` in flow-host.mjs), so the runner can
/// do what acpx's does with them.
enum FlowJS {
    /// The key of a marker object, which no flow's own object has.
    static let markerKey = "\u{0}acpx"
    /// Where the host puts the arguments the command gets, as Node's `spawn` converts them.
    static let argvKey = "\u{0}argv"
    /// What converting the arguments, or `env`, threw — as Node's `spawn` would.
    static let argvErrorKey = "\u{0}argvError"
    static let envErrorKey = "\u{0}envError"

    enum Marker: Equatable {
        /// `undefined`, a function or a symbol: what `JSON.stringify` leaves out.
        case undefined
        /// A BigInt, by its digits.
        case bigint(String)
        /// A value `JSON.stringify` throws for, a cycle, by the message it throws.
        case unserializable(String)
        /// A number JSON has no literal for — `NaN`, `Infinity`, `-Infinity` — which it
        /// writes as `null`.
        case number(Double)
        /// An object, a function or a symbol given as one of the spec's own members — a URL,
        /// a Date — which JSON would write as something else: Node's name for its type,
        /// `String` of it, and its JSON (`toJSON`).
        case instance(received: String, string: String, json: WireJSON)
        /// A value Node refuses where it reads it, by its error: a URL `cwd` of another scheme
        /// among spawn options, their `env` with a value that cannot be a string.
        case refused(message: String, code: String?)
    }

    static func marker(_ value: WireJSON) -> Marker? {
        guard case .object(let members) = value, members.first?.key == Array(markerKey.utf16) else { return nil }
        switch value[markerKey]?.stringValue {
        case "undefined": return .undefined
        case "bigint": return .bigint(value["text"]?.stringValue ?? "")
        case "unserializable": return .unserializable(value["text"]?.stringValue ?? "")
        case "number": return .number(JavaScriptNumber.parse(value["text"]?.stringValue ?? ""))
        case "instance":
            return .instance(
                received: value["text"]?.stringValue ?? "an instance of Object",
                string: value["string"]?.stringValue ?? "", json: value["json"] ?? .null)
        case "refused": return .refused(message: value["text"]?.stringValue ?? "", code: value["code"]?.stringValue)
        default: return nil
        }
    }

    /// JavaScript's `String(value)`.
    static func string(_ value: WireJSON) -> String {
        switch marker(value) {
        case .undefined?: return "undefined"
        case .bigint(let digits)?: return digits
        case .unserializable?: return "[object Object]"
        case .number(let number)?: return WireJSON.javaScriptString(forNonFinite: number)
        case .instance(_, let string, _)?: return string
        case .refused?: return ""
        case nil: return SessionArchive.javaScriptString(value)
        }
    }

    /// The value as `JSON.stringify` writes it — `nil` for one it leaves out, `null` in a
    /// list — or the error it throws, for a BigInt or a value it cannot write.
    static func written(_ value: WireJSON) throws -> WireJSON? {
        switch marker(value) {
        case .undefined?: return nil
        case .bigint?: throw FlowShellError("Do not know how to serialize a BigInt", name: "TypeError")
        case .unserializable(let message)?: throw FlowShellError(message, name: "TypeError")
        case .number?: return .null
        case .instance(_, _, let json)?: return try written(json)
        case .refused?: return nil
        case nil: break
        }
        switch value {
        case .array(let items):
            return .array(try items.map { try written($0) ?? .null })
        case .object(let members):
            return .object(try members.compactMap { member in
                guard let kept = try written(member.value) else { return nil }
                var copy = member
                copy.key = unescaped(member.key)
                copy.value = kept
                return copy
            })
        default:
            return value
        }
    }

    /// An object's key as the flow wrote it: the host escapes one that starts with a NUL
    /// with another, so none passes for a marker.
    static func unescaped(_ key: [UInt16]) -> [UInt16] {
        key.starts(with: [0, 0]) ? Array(key.dropFirst()) : key
    }

    /// JavaScript's truthiness.
    static func truthy(_ value: WireJSON?) -> Bool {
        switch value {
        case nil, .null?, .bool(false)?: return false
        case .number(let number)?: return number != 0 && !number.isNaN
        case .string(let units)?: return !units.isEmpty
        case let other?:
            switch marker(other) {
            case .undefined?: return false
            case .bigint(let digits)?: return digits != "0"
            case .number(let number)?: return !number.isNaN
            default: return true
            }
        }
    }

    /// Node's `determineSpecificType` for a marked value.
    static func received(_ marker: Marker) -> String {
        switch marker {
        case .undefined: return "undefined"
        case .bigint(let digits): return "type bigint (\(digits)n)"
        case .unserializable: return "an instance of Object"
        case .number(let number): return "type number (\(WireJSON.javaScriptString(forNonFinite: number)))"
        case .instance(let received, _, _): return received
        case .refused: return "undefined"
        }
    }
}

/// Node's `util.inspect` of a string, as its errors show a value (`ERR_INVALID_ARG_VALUE`):
/// quoted with a quote the text lacks — single, else double, else a backtick — control
/// characters escaped, and one longer than 124 units split after each line break.
enum NodeInspect {
    static func string(_ text: String) -> String {
        let units = Array(text.utf16)
        guard units.count > 124 else { return quoted(units) }
        var pieces: [[UInt16]] = []
        var piece: [UInt16] = []
        for unit in units {
            piece.append(unit)
            if unit == 0x0A {
                pieces.append(piece)
                piece = []
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces.map(quoted).joined(separator: " +\n  ")
    }

    private static func quoted(_ units: [UInt16]) -> String {
        var quote: UInt16 = 0x27
        if units.contains(0x27) {
            if !units.contains(0x22) {
                quote = 0x22
            } else if !units.contains(0x60), !String(decoding: units, as: UTF16.self).contains("${") {
                quote = 0x60
            }
        }
        var text: [UInt16] = [quote]
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            if unit == 0x27, quote == 0x27 {
                text += Array("\\'".utf16)
            } else if unit == 0x5C {
                text += Array("\\\\".utf16)
            } else if unit < 0x20 || (0x7F...0x9F).contains(unit) {
                text += Array(escape(unit).utf16)
            } else if (0xD800...0xDBFF).contains(unit), index < units.count, (0xDC00...0xDFFF).contains(units[index]) {
                text += [unit, units[index]]
                index += 1
            } else if (0xD800...0xDFFF).contains(unit) {
                text += Array("\\u\(String(unit, radix: 16))".utf16)
            } else {
                text.append(unit)
            }
        }
        text.append(quote)
        return String(decoding: text, as: UTF16.self)
    }

    private static func escape(_ unit: UInt16) -> String {
        switch unit {
        case 0x08: return "\\b"
        case 0x09: return "\\t"
        case 0x0A: return "\\n"
        case 0x0C: return "\\f"
        case 0x0D: return "\\r"
        default: return "\\x" + (unit < 0x10 ? "0" : "") + String(unit, radix: 16, uppercase: true)
        }
    }
}

extension WireJSON {
    /// JavaScript's `String(number)` for one JSON has no literal for.
    static func javaScriptString(forNonFinite number: Double) -> String {
        number.isNaN ? "NaN" : number > 0 ? "Infinity" : "-Infinity"
    }
}

extension FlowShellError {
    /// Node's `ERR_INVALID_ARG_VALUE`: a `TypeError` naming the argument, or the property
    /// for a dotted name, the value inspected and cut at 128 characters.
    static func invalidArgValue(_ name: String, _ value: String, reason: String) -> FlowShellError {
        var inspected = NodeInspect.string(value)
        if inspected.utf16.count > 128 {
            inspected = String(decoding: inspected.utf16.prefix(128), as: UTF16.self) + "..."
        }
        let kind = name.contains(".") ? "property" : "argument"
        return FlowShellError("The \(kind) '\(name)' \(reason). Received \(inspected)", code: "ERR_INVALID_ARG_VALUE")
    }

    /// Node's check that a string it passes to the OS has no NUL.
    static func checkNullBytes(
        _ value: String, _ name: String, reason: String = "must be a string without null bytes"
    ) throws {
        guard value.utf16.contains(0) else { return }
        throw invalidArgValue(name, value, reason: reason)
    }
}
