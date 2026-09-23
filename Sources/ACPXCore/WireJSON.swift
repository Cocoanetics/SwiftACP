import Foundation

/// A JSON value as JavaScript's `JSON.parse` sees it, so that ``stringified`` is what
/// `JSON.stringify` would print for it — byte for byte what acpx writes when it echoes
/// a message it parsed.
///
/// That differs from re-encoding with `JSONEncoder` in three ways that show on the
/// wire: object members keep the order they arrived in (and a repeated key keeps its
/// first position with its last value), numbers are doubles printed the way
/// JavaScript prints them (`1.0` → `1`, `1e21` → `1e+21`), and strings are UTF-16 code
/// units, so a lone surrogate survives to be escaped as `\udXXX` while every other
/// character — `é`, `/`, U+2028 — is printed as itself.
public indirect enum WireJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    /// UTF-16 code units, as JavaScript holds a string.
    case string([UInt16])
    case array([WireJSON])
    case object([Member])

    /// One object member. Keys are UTF-16 too: a key can hold a lone surrogate.
    public struct Member: Equatable, Sendable {
        public var key: [UInt16]
        public var value: WireJSON

        public init(key: [UInt16], value: WireJSON) {
            self.key = key
            self.value = value
        }

        public init(_ key: String, _ value: WireJSON) {
            self.init(key: Array(key.utf16), value: value)
        }
    }

    /// Nesting beyond this is refused rather than risking the stack of the thread the
    /// wire is read on; no ACP message comes near it.
    static let maxDepth = 512

    // MARK: - Parsing (JSON.parse)

    /// Parse `data` as UTF-8 JSON text — invalid sequences become U+FFFD, as the
    /// `TextDecoder` acpx reads the agent with makes them. `nil` when the text is not
    /// a single JSON value (surrounded by JSON whitespace only).
    public init?(parsing data: Data) {
        self.init(parsing: String(decoding: data, as: UTF8.self))
    }

    public init?(parsing text: String) {
        var parser = Parser(units: Array(text.utf16))
        guard let value = parser.parseDocument() else { return nil }
        self = value
    }

    private struct Parser {
        let units: [UInt16]
        var index = 0

        init(units: [UInt16]) { self.units = units }

        mutating func parseDocument() -> WireJSON? {
            skipWhitespace()
            guard let value = parseValue(depth: 0) else { return nil }
            skipWhitespace()
            return index == units.count ? value : nil
        }

        /// JSON whitespace only: tab, line feed, carriage return, space.
        mutating func skipWhitespace() {
            while index < units.count, [0x09, 0x0A, 0x0D, 0x20].contains(units[index]) { index += 1 }
        }

        mutating func parseValue(depth: Int) -> WireJSON? {
            guard depth <= WireJSON.maxDepth, index < units.count else { return nil }
            switch units[index] {
            case 0x7B: return parseObject(depth: depth)
            case 0x5B: return parseArray(depth: depth)
            case 0x22: return parseString().map(WireJSON.string)
            case 0x74: return parseLiteral("true", .bool(true))
            case 0x66: return parseLiteral("false", .bool(false))
            case 0x6E: return parseLiteral("null", .null)
            default: return parseNumber()
            }
        }

        mutating func parseLiteral(_ word: String, _ value: WireJSON) -> WireJSON? {
            let expected = Array(word.utf16)
            guard units.count - index >= expected.count,
                Array(units[index..<index + expected.count]) == expected
            else { return nil }
            index += expected.count
            return value
        }

        mutating func parseObject(depth: Int) -> WireJSON? {
            index += 1  // {
            var members: [Member] = []
            var positions: [[UInt16]: Int] = [:]
            skipWhitespace()
            if index < units.count, units[index] == 0x7D {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < units.count, units[index] == 0x22, let key = parseString() else { return nil }
                skipWhitespace()
                guard index < units.count, units[index] == 0x3A else { return nil }
                index += 1
                skipWhitespace()
                guard let value = parseValue(depth: depth + 1) else { return nil }
                // JSON.parse defines each member with CreateDataProperty: a repeated
                // key takes the new value but keeps its original position.
                if let existing = positions[key] {
                    members[existing].value = value
                } else {
                    positions[key] = members.count
                    members.append(Member(key: key, value: value))
                }
                skipWhitespace()
                guard index < units.count else { return nil }
                if units[index] == 0x2C {
                    index += 1
                    continue
                }
                guard units[index] == 0x7D else { return nil }
                index += 1
                return .object(members)
            }
        }

        mutating func parseArray(depth: Int) -> WireJSON? {
            index += 1  // [
            var items: [WireJSON] = []
            skipWhitespace()
            if index < units.count, units[index] == 0x5D {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                guard let item = parseValue(depth: depth + 1) else { return nil }
                items.append(item)
                skipWhitespace()
                guard index < units.count else { return nil }
                if units[index] == 0x2C {
                    index += 1
                    continue
                }
                guard units[index] == 0x5D else { return nil }
                index += 1
                return .array(items)
            }
        }

        /// A string literal, escapes resolved to code units. Raw control characters
        /// are a syntax error, as in JSON.parse.
        mutating func parseString() -> [UInt16]? {
            index += 1  // opening quote
            var result: [UInt16] = []
            while index < units.count {
                let unit = units[index]
                index += 1
                switch unit {
                case 0x22:
                    return result
                case 0x5C:
                    guard index < units.count else { return nil }
                    let escape = units[index]
                    index += 1
                    switch escape {
                    case 0x22, 0x5C, 0x2F: result.append(escape)
                    case 0x62: result.append(0x08)
                    case 0x66: result.append(0x0C)
                    case 0x6E: result.append(0x0A)
                    case 0x72: result.append(0x0D)
                    case 0x74: result.append(0x09)
                    case 0x75:
                        guard units.count - index >= 4 else { return nil }
                        var value: UInt16 = 0
                        for digit in units[index..<index + 4] {
                            guard let nibble = Self.hexValue(digit) else { return nil }
                            value = value << 4 | nibble
                        }
                        index += 4
                        result.append(value)
                    default: return nil
                    }
                default:
                    guard unit >= 0x20 else { return nil }
                    result.append(unit)
                }
            }
            return nil
        }

        static func hexValue(_ unit: UInt16) -> UInt16? {
            switch unit {
            case 0x30...0x39: return unit - 0x30
            case 0x41...0x46: return unit - 0x41 + 10
            case 0x61...0x66: return unit - 0x61 + 10
            default: return nil
            }
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, read as a double
        /// with round-to-nearest (as JavaScript does; too large a magnitude is ±∞).
        mutating func parseNumber() -> WireJSON? {
            let start = index
            func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
            if index < units.count, units[index] == 0x2D { index += 1 }
            guard index < units.count, isDigit(units[index]) else { return nil }
            if units[index] == 0x30 {
                index += 1
            } else {
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
            if index < units.count, units[index] == 0x2E {
                index += 1
                guard index < units.count, isDigit(units[index]) else { return nil }
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
            if index < units.count, units[index] == 0x65 || units[index] == 0x45 {
                index += 1
                if index < units.count, units[index] == 0x2B || units[index] == 0x2D { index += 1 }
                guard index < units.count, isDigit(units[index]) else { return nil }
                while index < units.count, isDigit(units[index]) { index += 1 }
            }
            let literal = String(decoding: units[start..<index], as: UTF16.self)
            guard let value = Double(literal) else { return nil }
            return .number(value)
        }
    }

    // MARK: - Printing (JSON.stringify)

    /// The value as `JSON.stringify` prints it: no whitespace, members in property
    /// order (see ``orderedForPrinting``), JavaScript's number and string forms.
    public var stringified: String {
        var output: [UInt16] = []
        write(into: &output)
        return String(decoding: output, as: UTF16.self)
    }

    private func write(into output: inout [UInt16]) {
        switch self {
        case .null: output += "null".utf16
        case .bool(let flag): output += (flag ? "true" : "false").utf16
        case .number(let value): output += Self.javaScriptString(for: value).utf16
        case .string(let units): Self.writeQuoted(units, into: &output)
        case .array(let items):
            output.append(0x5B)
            for (offset, item) in items.enumerated() {
                if offset > 0 { output.append(0x2C) }
                item.write(into: &output)
            }
            output.append(0x5D)
        case .object(let members):
            output.append(0x7B)
            for (offset, member) in Self.orderedForPrinting(members).enumerated() {
                if offset > 0 { output.append(0x2C) }
                Self.writeQuoted(member.key, into: &output)
                output.append(0x3A)
                member.value.write(into: &output)
            }
            output.append(0x7D)
        }
    }

    /// A JavaScript object lists its array-index keys ("0", "1", … up to 2³² − 2)
    /// first, in ascending numeric order, then every other key in creation order —
    /// so `{"b":1,"2":0}` round-trips as `{"2":0,"b":1}`.
    static func orderedForPrinting(_ members: [Member]) -> [Member] {
        let indexed = members.compactMap { member in arrayIndex(member.key).map { ($0, member) } }
        guard !indexed.isEmpty else { return members }
        let rest = members.filter { arrayIndex($0.key) == nil }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1) + rest
    }

    /// `keys` as a JavaScript object built by inserting them in this order lists them:
    /// each once, where it was first inserted, with array-index keys first in numeric
    /// order — the order `Object.entries`, `Object.fromEntries` and `{...a, ...b}` keep.
    public static func propertyOrder(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        let unique = keys.filter { seen.insert($0).inserted }
        return orderedForPrinting(unique.map { Member($0, .null) })
            .map { String(decoding: $0.key, as: UTF16.self) }
    }

    /// The key's value as an array index: its canonical decimal form (no sign, no
    /// leading zero unless it is `0`) of an integer below 2³² − 1.
    static func arrayIndex(_ key: [UInt16]) -> UInt64? {
        guard !key.isEmpty, key.count <= 10, key.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        if key.count > 1, key[0] == 0x30 { return nil }
        let value = key.reduce(UInt64(0)) { $0 * 10 + UInt64($1 - 0x30) }
        return value < 4_294_967_295 ? value : nil
    }

    /// JSON.stringify's QuoteJSONString: the short escapes, `\u00XX` for other control
    /// characters and `\uXXXX` for a lone surrogate (lowercase hex); everything else,
    /// including `/`, DEL and U+2028, as itself.
    static func writeQuoted(_ units: [UInt16], into output: inout [UInt16]) {
        output.append(0x22)
        var index = 0
        while index < units.count {
            let unit = units[index]
            switch unit {
            case 0x22: output += "\\\"".utf16
            case 0x5C: output += "\\\\".utf16
            case 0x08: output += "\\b".utf16
            case 0x0C: output += "\\f".utf16
            case 0x0A: output += "\\n".utf16
            case 0x0D: output += "\\r".utf16
            case 0x09: output += "\\t".utf16
            case 0x00..<0x20: output += escaped(unit)
            case 0xD800...0xDBFF:
                if index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) {
                    output.append(unit)
                    output.append(units[index + 1])
                    index += 1
                } else {
                    output += escaped(unit)
                }
            case 0xDC00...0xDFFF: output += escaped(unit)
            default: output.append(unit)
            }
            index += 1
        }
        output.append(0x22)
    }

    private static func escaped(_ unit: UInt16) -> [UInt16] {
        let hex = String(unit, radix: 16)
        return Array(("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).utf16)
    }

    /// JavaScript's `Number.prototype.toString()` for a finite double (ECMA-262
    /// Number::toString), and `null` for ±∞ as JSON.stringify prints them. The digits
    /// are the shortest that round-trip — the same digits Swift's `description`
    /// chooses — laid out by JavaScript's rules: plain up to 21 integer digits, `0.`
    /// and up to six leading zeros for small fractions, exponent form otherwise.
    public static func javaScriptString(for value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }  // -0 too
        if value < 0 { return "-" + javaScriptString(for: -value) }
        let (digits, pointPosition) = shortestDigits(of: value)
        let length = digits.count
        let exponent = pointPosition
        if length <= exponent, exponent <= 21 {
            return digits + String(repeating: "0", count: exponent - length)
        }
        if 0 < exponent, exponent <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: exponent)
            return String(digits[..<split]) + "." + String(digits[split...])
        }
        if -6 < exponent, exponent <= 0 {
            return "0." + String(repeating: "0", count: -exponent) + digits
        }
        let power = exponent - 1
        let suffix = "e" + (power >= 0 ? "+" : "-") + String(abs(power))
        if length == 1 { return digits + suffix }
        return String(digits.prefix(1)) + "." + String(digits.dropFirst()) + suffix
    }

    /// `value` (positive, finite) as its shortest round-trip digits `d₁d₂…dₖ` and the
    /// position `n` of the decimal point, so that `value = 0.d₁d₂…dₖ × 10ⁿ`.
    static func shortestDigits(of value: Double) -> (digits: String, pointPosition: Int) {
        let text = value.description  // e.g. "1.0", "0.001", "1e-07", "1.25e+20"
        let parts = text.lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = pieces[0]
        let fraction = pieces.count > 1 ? pieces[1] : ""
        var digits = Array(integer + fraction)
        var point = integer.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        return (String(digits), point)
    }
}

// MARK: - Reading and replacing members

extension WireJSON {
    /// The member named `key`, when this is an object that has one.
    public subscript(key: String) -> WireJSON? {
        guard case .object(let members) = self else { return nil }
        let units = Array(key.utf16)
        return members.first { $0.key == units }?.value
    }

    /// Whether this is an object with a member named `key` (whatever its value).
    public func hasMember(_ key: String) -> Bool {
        guard case .object(let members) = self else { return false }
        let units = Array(key.utf16)
        return members.contains { $0.key == units }
    }

    /// This object with `key`'s value replaced in place — the member keeps its
    /// position, as a JavaScript spread-then-assign does. Unchanged when absent.
    public func replacing(_ key: String, with value: WireJSON) -> WireJSON {
        guard case .object(var members) = self else { return self }
        let units = Array(key.utf16)
        guard let index = members.firstIndex(where: { $0.key == units }) else { return self }
        members[index].value = value
        return .object(members)
    }

    /// The string, decoded (a lone surrogate becomes U+FFFD); `nil` for non-strings.
    public var stringValue: String? {
        guard case .string(let units) = self else { return nil }
        return String(decoding: units, as: UTF16.self)
    }

    /// A string value from Swift text.
    public static func text(_ string: String) -> WireJSON { .string(Array(string.utf16)) }
}
