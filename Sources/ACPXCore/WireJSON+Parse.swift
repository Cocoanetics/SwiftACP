import Foundation

// MARK: - Parsing (JSON.parse)

extension WireJSON {
    /// `JSON.parse`'s `SyntaxError`, in V8's words — what Node prints for the same
    /// text, down to the position, line and column.
    public struct SyntaxError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Parse `text` as `JSON.parse` does, or throw its ``SyntaxError``.
    public static func parse(_ text: String) throws -> WireJSON {
        var parser = WireJSONParser(units: Array(text.utf16))
        return try parser.parseDocument()
    }

    /// Parse `data` as UTF-8 JSON text — invalid sequences become U+FFFD, as the
    /// `TextDecoder` acpx reads the agent with makes them. `nil` when `JSON.parse`
    /// would throw.
    public init?(parsing data: Data) {
        self.init(parsing: String(decoding: data, as: UTF8.self))
    }

    public init?(parsing text: String) {
        guard let value = try? Self.parse(text) else { return nil }
        self = value
    }
}

/// V8's JSON parser, error for error: which message a malformed text gets, at which
/// position — a UTF-16 offset, with `(line L column C)` counting `\n`, `\r` and
/// `\r\n` — and, for an unexpected character, how much of the text it quotes.
private struct WireJSONParser {
    typealias SyntaxError = WireJSON.SyntaxError
    typealias Member = WireJSON.Member

    let units: [UInt16]
    var index = 0

    init(units: [UInt16]) { self.units = units }

    mutating func parseDocument() throws -> WireJSON {
        skipWhitespace()
        guard index < units.count else { throw unexpectedEnd }
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == units.count else {
            throw failure("Unexpected non-whitespace character after JSON", at: index, inJSON: false)
        }
        return value
    }

    /// JSON whitespace only: tab, line feed, carriage return, space.
    mutating func skipWhitespace() {
        while index < units.count, [0x09, 0x0A, 0x0D, 0x20].contains(units[index]) { index += 1 }
    }

    mutating func parseValue(depth: Int) throws -> WireJSON {
        skipWhitespace()
        guard index < units.count else { throw unexpectedEnd }
        guard depth <= WireJSON.maxDepth else { throw SyntaxError(message: "Maximum call stack size exceeded") }
        switch units[index] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74: return try parseLiteral("true", .bool(true))
        case 0x66: return try parseLiteral("false", .bool(false))
        case 0x6E: return try parseLiteral("null", .null)
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: throw unexpectedToken(at: index)
        }
    }

    mutating func parseLiteral(_ word: String, _ value: WireJSON) throws -> WireJSON {
        for (offset, expected) in word.utf16.enumerated() {
            let position = index + offset
            guard position < units.count else { throw unexpectedEnd }
            guard units[position] == expected else { throw unexpectedToken(at: position) }
        }
        index += word.utf16.count
        return value
    }

    mutating func parseObject(depth: Int) throws -> WireJSON {
        index += 1  // {
        var members: [Member] = []
        var positions: [[UInt16]: Int] = [:]
        skipWhitespace()
        if index < units.count, units[index] == 0x7D {
            index += 1
            return .object(members)
        }
        guard index < units.count, units[index] == 0x22 else {
            throw failure("Expected property name or '}'", at: index)
        }
        while true {
            let key = try parseString()
            skipWhitespace()
            guard index < units.count, units[index] == 0x3A else {
                throw failure("Expected ':' after property name", at: index)
            }
            index += 1
            let value = try parseValue(depth: depth + 1)
            // JSON.parse defines each member with CreateDataProperty: a repeated
            // key takes the new value but keeps its original position.
            if let existing = positions[key] {
                members[existing].value = value
            } else {
                positions[key] = members.count
                members.append(Member(key: key, value: value))
            }
            skipWhitespace()
            if index < units.count, units[index] == 0x2C {
                index += 1
                skipWhitespace()
                guard index < units.count, units[index] == 0x22 else {
                    throw failure("Expected double-quoted property name", at: index)
                }
                continue
            }
            guard index < units.count, units[index] == 0x7D else {
                throw failure("Expected ',' or '}' after property value", at: index)
            }
            index += 1
            return .object(members)
        }
    }

    mutating func parseArray(depth: Int) throws -> WireJSON {
        index += 1  // [
        var items: [WireJSON] = []
        skipWhitespace()
        if index < units.count, units[index] == 0x5D {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if index < units.count, units[index] == 0x2C {
                index += 1
                continue
            }
            guard index < units.count, units[index] == 0x5D else {
                throw failure("Expected ',' or ']' after array element", at: index)
            }
            index += 1
            return .array(items)
        }
    }

    /// A string literal, escapes resolved to code units.
    mutating func parseString() throws -> [UInt16] {
        index += 1  // opening quote
        var result: [UInt16] = []
        while true {
            guard index < units.count else { throw failure("Unterminated string", at: units.count) }
            let unit = units[index]
            switch unit {
            case 0x22:
                index += 1
                return result
            case 0x5C:
                index += 1
                guard index < units.count else { throw unexpectedEnd }
                switch units[index] {
                case 0x22, 0x5C, 0x2F: result.append(units[index])
                case 0x62: result.append(0x08)
                case 0x66: result.append(0x0C)
                case 0x6E: result.append(0x0A)
                case 0x72: result.append(0x0D)
                case 0x74: result.append(0x09)
                case 0x75:
                    var value: UInt16 = 0
                    for _ in 0..<4 {
                        index += 1
                        guard index < units.count, let nibble = Self.hexValue(units[index]) else {
                            throw failure("Bad Unicode escape", at: min(index, units.count))
                        }
                        value = value << 4 | nibble
                    }
                    result.append(value)
                default:
                    throw failure("Bad escaped character", at: index)
                }
                index += 1
            case 0x00..<0x20:
                throw failure("Bad control character in string literal", at: index)
            default:
                result.append(unit)
                index += 1
            }
        }
    }

    static func hexValue(_ unit: UInt16) -> UInt16? {
        switch unit {
        case 0x30...0x39: return unit - 0x30
        case 0x41...0x46: return unit - 0x41 + 10
        case 0x61...0x66: return unit - 0x61 + 10
        default: return nil
        }
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, read as a double with
    /// round-to-nearest, as JavaScript does (too large a magnitude is ±∞).
    mutating func parseNumber() throws -> WireJSON {
        let start = index
        func isDigit(_ position: Int) -> Bool {
            position < units.count && (0x30...0x39).contains(units[position])
        }
        if units[index] == 0x2D {
            index += 1
            guard isDigit(index) else { throw failure("No number after minus sign", at: index) }
        }
        if units[index] == 0x30 {
            index += 1
            if isDigit(index) { throw failure("Unexpected number", at: index) }
        } else {
            while isDigit(index) { index += 1 }
        }
        if index < units.count, units[index] == 0x2E {
            index += 1
            guard isDigit(index) else { throw failure("Unterminated fractional number", at: index) }
            while isDigit(index) { index += 1 }
        }
        if index < units.count, units[index] == 0x65 || units[index] == 0x45 {
            index += 1
            if index < units.count, units[index] == 0x2B || units[index] == 0x2D { index += 1 }
            guard isDigit(index) else { throw failure("Exponent part is missing a number", at: index) }
            while isDigit(index) { index += 1 }
        }
        let literal = String(decoding: units[start..<index], as: UTF16.self)
        guard let value = Double(literal) else { throw unexpectedToken(at: start) }
        return .number(value)
    }

    // MARK: V8's messages

    var unexpectedEnd: SyntaxError { SyntaxError(message: "Unexpected end of JSON input") }

    /// `<what> in JSON at position N (line L column C)` — without the `in JSON` for a
    /// message that already says where.
    func failure(_ what: String, at position: Int, inJSON: Bool = true) -> SyntaxError {
        var line = 1
        var lastBreak = -1
        var offset = 0
        while offset < position {
            if units[offset] == 0x0A {
                line += 1
                lastBreak = offset
            } else if units[offset] == 0x0D {
                if offset + 1 < position, units[offset + 1] == 0x0A { offset += 1 }
                line += 1
                lastBreak = offset
            }
            offset += 1
        }
        let place = inJSON ? " in JSON" : ""
        return SyntaxError(
            message: "\(what)\(place) at position \(position) (line \(line) column \(position - lastBreak))")
    }

    /// V8's `ReportUnexpectedToken`: the character, and the text — all of it when
    /// shorter than 21 code units, otherwise ten on either side, `...` marking the cut.
    /// The texts JavaScript produces from non-JSON values get their own message.
    func unexpectedToken(at position: Int) -> SyntaxError {
        let whole = String(decoding: units, as: UTF16.self)
        if ["NaN", "Infinity", "undefined", "[object Object]"].contains(whole) {
            return SyntaxError(message: "\"\(whole)\" is not valid JSON")
        }
        let token = String(decoding: units[position...position], as: UTF16.self)
        let context = 10
        let count = units.count
        func text(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }
        let quoted: String
        if count < 2 * context + 1 {
            quoted = "\"\(whole)\""
        } else if position < context {
            quoted = "\"\(text(0..<position + context))\"..."
        } else if position < count - context {
            quoted = "...\"\(text(position - context..<position + context))\"..."
        } else {
            quoted = "...\"\(text(position - context..<count))\""
        }
        return SyntaxError(message: "Unexpected token '\(token)', \(quoted) is not valid JSON")
    }
}
