import Foundation
import JSONFoundation
import SwiftACP

/// acpx's config validation — `cli/config.ts` and `mcp-servers.ts` — message for
/// message, over a file parsed as `JSON.parse` parses it (``WireJSON``). A value that is
/// absent or `null` is "not set", as `value == null` is upstream; anything else must be
/// valid or the whole config is refused, naming the field and the file.
enum ConfigFields {
    /// A config file as acpx holds it: its path (for messages) and its top-level object.
    struct File {
        let path: String
        let root: WireJSON

        subscript(key: String) -> WireJSON? { root[key] }
        func has(_ key: String) -> Bool { root.hasMember(key) }
    }

    /// Node's largest `setTimeout` delay (`MAX_TIMER_DELAY_MS`).
    static let maxTimerDelayMs = 2_147_483_647

    static func isUnset(_ value: WireJSON?) -> Bool { value == nil || value == .null }

    /// The string, when the value is one.
    static func string(_ value: WireJSON?) -> String? {
        guard case .string? = value else { return nil }
        return value?.stringValue
    }

    // MARK: Scalars

    static func ttlMs(_ value: WireJSON?, _ path: String) throws -> Int? {
        if isUnset(value) { return nil }
        guard case .number(let seconds)? = value, seconds.isFinite, seconds >= 0 else {
            throw ConfigError("Invalid config ttl in \(path): expected non-negative seconds")
        }
        guard let milliseconds = timerMilliseconds(seconds, allowZero: true) else {
            throw ConfigError("Invalid config ttl in \(path): exceeds maximum supported timer delay")
        }
        return milliseconds
    }

    static func timeoutMs(_ value: WireJSON?, _ path: String) throws -> Int? {
        if isUnset(value) { return nil }
        guard case .number(let seconds)? = value, seconds.isFinite, seconds > 0 else {
            throw ConfigError("Invalid config timeout in \(path): expected positive seconds or null")
        }
        guard let milliseconds = timerMilliseconds(seconds, allowZero: false) else {
            throw ConfigError("Invalid config timeout in \(path): exceeds maximum supported timer delay")
        }
        return milliseconds
    }

    /// `toTimerMilliseconds`: zero stays zero where allowed; anything else is at least
    /// 1 ms, rounded half up as `Math.round` rounds, and within the timer maximum.
    static func timerMilliseconds(_ seconds: Double, allowZero: Bool) -> Int? {
        if allowZero && seconds == 0 { return 0 }
        let milliseconds = max(1, (seconds * 1000 + 0.5).rounded(.down))
        return milliseconds <= Double(maxTimerDelayMs) ? Int(milliseconds) : nil
    }

    static func queueMaxDepth(_ value: WireJSON?, _ path: String) throws -> Int? {
        if isUnset(value) { return nil }
        guard case .number(let depth)? = value, depth.isFinite, depth.rounded() == depth, depth > 0 else {
            throw ConfigError("Invalid config queueMaxDepth in \(path): expected positive integer")
        }
        return Int(exactly: depth) ?? Int.max
    }

    /// A string that must be one of `allowed`.
    static func choice(
        _ value: WireJSON?, _ path: String, field: String, allowed: [String], expected: String
    ) throws -> String? {
        if isUnset(value) { return nil }
        guard let text = string(value), allowed.contains(text) else {
            throw ConfigError("Invalid config \(field) in \(path): expected \(expected)")
        }
        return text
    }

    static func defaultAgent(_ value: WireJSON?, _ path: String) throws -> String? {
        if isUnset(value) { return nil }
        guard let text = string(value), !text.javaScriptTrimmed.isEmpty else {
            throw ConfigError("Invalid config defaultAgent in \(path): expected non-empty string")
        }
        return text.javaScriptTrimmed.lowercased()
    }

    static func disableExec(_ value: WireJSON?, _ path: String) throws -> Bool? {
        if isUnset(value) { return nil }
        guard case .bool(let flag)? = value else {
            throw ConfigError("Invalid config disableExec in \(path): expected boolean")
        }
        return flag
    }

    // MARK: Agents and auth

    /// `parseAgents`: each entry's launch command, under its normalized name, in
    /// `Object.entries` order.
    static func agents(_ value: WireJSON?, _ path: String) throws -> [(name: String, command: String)]? {
        if isUnset(value) { return nil }
        guard case .object(let members)? = value else {
            throw ConfigError("Invalid config agents in \(path): expected object")
        }
        return try WireJSON.orderedForPrinting(members).map { member in
            let name = String(decoding: member.key, as: UTF16.self)
            return (name.javaScriptTrimmed.lowercased(), try agentCommand(member.value, name: name, path))
        }
    }

    /// `parseAgentEntry`: an `argv` vector on its own, or a `command` string with
    /// optional `args` — resolved to the command line acpx shows for it.
    static func agentCommand(_ raw: WireJSON, name: String, _ path: String) throws -> String {
        guard case .object = raw else {
            throw ConfigError("Invalid config agents.\(name) in \(path): expected object with command")
        }
        if raw.hasMember("argv") {
            guard !raw.hasMember("command"), !raw.hasMember("args") else {
                throw ConfigError("Invalid config agents.\(name) in \(path): use argv alone, not command or args")
            }
            return renderArgvIdentity(try argv(raw["argv"], name: name, path))
        }
        guard let command = string(raw["command"]), !command.javaScriptTrimmed.isEmpty else {
            throw ConfigError("Invalid config agents.\(name).command in \(path): expected non-empty string")
        }
        let trimmed = command.javaScriptTrimmed
        guard raw.hasMember("args") else { return trimmed }
        guard !trimmed.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) else {
            throw ConfigError(
                "Invalid config agents.\(name).command in \(path): command must be an unquoted executable "
                    + "with no whitespace when args is present; migrate the complete launch to argv")
        }
        let args = try agentArgs(raw["args"], name: name, path)
        return ([trimmed] + args.map { WireJSON.text($0).stringified }).joined(separator: " ")
    }

    static func argv(_ value: WireJSON?, name: String, _ path: String) throws -> [String] {
        guard case .array(let items)? = value, !items.isEmpty else {
            throw ConfigError("Invalid config agents.\(name).argv in \(path): expected non-empty array of strings")
        }
        let argv = try items.enumerated().map { index, item in
            guard let arg = string(item) else {
                throw ConfigError("Invalid config agents.\(name).argv[\(index)] in \(path): expected string")
            }
            return arg
        }
        guard !argv[0].isEmpty else {
            throw ConfigError("Invalid config agents.\(name).argv[0] in \(path): expected non-empty executable")
        }
        return argv
    }

    static func agentArgs(_ value: WireJSON?, name: String, _ path: String) throws -> [String] {
        if isUnset(value) { return [] }
        guard case .array(let items)? = value else {
            throw ConfigError("Invalid config agents.\(name).args in \(path): expected array of strings")
        }
        return try items.enumerated().map { index, item in
            guard let arg = string(item) else {
                throw ConfigError("Invalid config agents.\(name).args[\(index)] in \(path): expected string")
            }
            return arg
        }
    }

    /// `renderArgvIdentity`: each argument as it is when it is plainly safe, else quoted.
    static func renderArgvIdentity(_ argv: [String]) -> String {
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./^~-")
        return argv.map { arg in
            !arg.isEmpty && arg.unicodeScalars.allSatisfy(safe.contains) ? arg : WireJSON.text(arg).stringified
        }.joined(separator: " ")
    }

    static func auth(_ value: WireJSON?, _ path: String) throws -> [(methodId: String, credential: String)]? {
        if isUnset(value) { return nil }
        guard case .object(let members)? = value else {
            throw ConfigError("Invalid config auth in \(path): expected object")
        }
        return try WireJSON.orderedForPrinting(members).map { member in
            let methodId = String(decoding: member.key, as: UTF16.self)
            guard let credential = string(member.value), !credential.javaScriptTrimmed.isEmpty else {
                throw ConfigError("Invalid config auth.\(methodId) in \(path): expected non-empty string")
            }
            return (methodId, credential)
        }
    }

    // MARK: MCP servers

    /// `parseMcpServers`. Upstream's paths put a field after the file — `Invalid
    /// mcpServers[0] in <file>.name` — and so do these.
    static func mcpServers(_ value: WireJSON?, _ path: String) throws -> [McpServerConfig] {
        guard case .array(let items)? = value else {
            throw ConfigError("Invalid mcpServers in \(path): expected array")
        }
        return try items.enumerated().map { index, raw in try mcpServer(raw, "mcpServers[\(index)] in \(path)") }
    }

    /// Fields the file left out stay out (`nil`), where acpx fills in empty lists: the
    /// wire form is the same either way (``McpServerConfig/protocolSpec()``), and a
    /// record that keeps a session's own servers keeps them as they were written.
    static func mcpServer(_ raw: WireJSON, _ path: String) throws -> McpServerConfig {
        guard case .object = raw else { throw ConfigError("Invalid \(path): expected object") }
        let name = try nonEmptyString(raw["name"], "\(path).name")
        let meta = try mcpMeta(raw["_meta"], "\(path)._meta")
        let type = try serverType(raw["type"], path)
        if type == "http" || type == "sse" {
            return McpServerConfig(
                type: type, name: name, url: try nonEmptyString(raw["url"], "\(path).url"),
                headers: try nameValuePairs(raw["headers"], "\(path).headers"), meta: meta)
        }
        return McpServerConfig(
            type: raw.hasMember("type") ? type : nil,
            name: name, command: try nonEmptyString(raw["command"], "\(path).command"),
            args: try mcpArgs(raw["args"], "\(path).args"), env: try nameValuePairs(raw["env"], "\(path).env"),
            meta: meta)
    }

    /// An omitted type is stdio; one given must be http, sse or stdio.
    static func serverType(_ value: WireJSON?, _ path: String) throws -> String {
        guard let value else { return "stdio" }
        let type = try nonEmptyString(value, "\(path).type")
        guard ["http", "sse", "stdio"].contains(type) else {
            throw ConfigError("Invalid \(path).type: expected http, sse, or stdio")
        }
        return type
    }

    static func nonEmptyString(_ value: WireJSON?, _ path: String) throws -> String {
        guard let text = string(value), !text.javaScriptTrimmed.isEmpty else {
            throw ConfigError("Invalid \(path): expected non-empty string")
        }
        return text.javaScriptTrimmed
    }

    static func mcpArgs(_ value: WireJSON?, _ path: String) throws -> [String]? {
        if isUnset(value) { return nil }
        guard case .array(let items)? = value else { throw ConfigError("Invalid \(path): expected array") }
        return try items.enumerated().map { index, item in
            guard let arg = string(item) else { throw ConfigError("Invalid \(path)[\(index)]: expected string") }
            return arg
        }
    }

    static func nameValuePairs(_ value: WireJSON?, _ path: String) throws -> [McpServerConfig.EnvEntry]? {
        if isUnset(value) { return nil }
        guard case .array(let items)? = value else { throw ConfigError("Invalid \(path): expected array") }
        return try items.enumerated().map { index, raw in
            guard case .object = raw else { throw ConfigError("Invalid \(path)[\(index)]: expected object") }
            let name = try nonEmptyString(raw["name"], "\(path)[\(index)].name")
            guard let value = string(raw["value"]) else {
                throw ConfigError("Invalid \(path)[\(index)].value: expected string")
            }
            return McpServerConfig.EnvEntry(name: name, value: value)
        }
    }

    /// `_meta`: an object, `null` (sent as nothing here), or absent.
    static func mcpMeta(_ value: WireJSON?, _ path: String) throws -> [String: JSONValue]? {
        guard let value, value != .null else { return nil }
        guard case .object(let members) = value else {
            throw ConfigError("Invalid \(path): expected object or null")
        }
        return Dictionary(
            members.map { (String(decoding: $0.key, as: UTF16.self), $0.value.jsonValue) },
            uniquingKeysWith: { _, last in last })
    }
}

extension String {
    /// `String.prototype.trim`: JavaScript's whitespace (the space separators, tab,
    /// vertical tab, form feed and the BOM) and line terminators — not Foundation's
    /// `whitespacesAndNewlines`, which also takes U+0085.
    public var javaScriptTrimmed: String {
        trimmingCharacters(in: javaScriptWhitespace)
    }
}

private let javaScriptWhitespace = CharacterSet(
    charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
).union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))

extension WireJSON {
    /// A JSONFoundation value, to print as `JSON.stringify` would. `JSONValue` keeps no
    /// member order, so an object's keys go in sorted order.
    public init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .integer(let number): self = .number(Double(number))
        case .unsignedInteger(let number): self = .number(Double(number))
        case .double(let number): self = .number(number)
        case .string(let text): self = .text(text)
        case .array(let items): self = .array(items.map(WireJSON.init))
        case .object(let members):
            self = .object(members.keys.sorted().map { key in Member(key, WireJSON(members[key] ?? .null)) })
        }
    }

    /// The value as JSONFoundation's `JSONValue` — object member order is lost. A number
    /// too large for a double (`1e400`) parses to infinity, as in `JSON.parse`, and
    /// becomes `null`, which is how `JSON.stringify` sends it on.
    var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let value):
            guard value.isFinite else { return .null }
            return value.rounded() == value && abs(value) < 9e15 ? .integer(Int(value)) : .double(value)
        case .string: return .string(stringValue ?? "")
        case .array(let items): return .array(items.map(\.jsonValue))
        case .object(let members):
            return .object(Dictionary(
                members.map { (String(decoding: $0.key, as: UTF16.self), $0.value.jsonValue) },
                uniquingKeysWith: { _, last in last }))
        }
    }
}
