import Foundation
import SwiftACP

/// acpx's `parseSessionRecord` (`src/session/persistence/parse.ts`): what acpx makes of
/// a stored session record. The result is acpx's in-memory record — what `sessions
/// show` and `sessions list` print with `JSON.stringify` — or `nil` for a file acpx does
/// not take for a record at all.
///
/// It works on the file as parsed, so member order, and fields SwiftACP's model does
/// not know, survive the way acpx keeps them. The record's own fields come out
/// camelCase, in the order acpx builds them. The conversation keeps its stored
/// snake_case names. An invalid field is dropped, rewritten or makes the whole record
/// invalid, field by field as acpx's parser decides.
public enum SessionRecordParser {
    /// A field as acpx's parser leaves it.
    enum Parsed: Equatable {
        /// Left out: `undefined`, which `JSON.stringify` does not print.
        case undefined
        /// Kept — `null` included, where acpx keeps a `null`.
        case kept(WireJSON)
        /// Not a value acpx accepts there: the whole record is invalid.
        case invalid

        var value: WireJSON? {
            if case .kept(let value) = self { return value }
            return nil
        }
    }

    /// The in-memory record acpx makes of `raw`, or `nil` when it rejects the file.
    public static func parse(_ raw: WireJSON) -> WireJSON? {
        guard case .object = raw, raw["schema"] == .text(SESSION_RECORD_SCHEMA),
            let recordId = raw["acpx_record_id"]?.stringValue
        else { return nil }
        let name = optionalName(raw["name"])
        let pid = optionalPid(raw["pid"])
        let closed = optionalBoolean(raw["closed"])
        let closedAt = optionalString(raw["closed_at"])
        let agentStartedAt = optionalString(raw["agent_started_at"])
        let lastPromptAt = optionalString(raw["last_prompt_at"])
        let exitCode = optionalExitCode(raw["last_agent_exit_code"])
        let exitSignal = optionalSignal(raw["last_agent_exit_signal"])
        let exitAt = optionalString(raw["last_agent_exit_at"])
        let disconnectReason = optionalString(raw["last_agent_disconnect_reason"])
        let lastRequestId = optionalString(raw["last_request_id"])
        let importedFrom = importedFrom(raw["imported_from"])
        let fields = [
            name, pid, closed, closedAt, agentStartedAt, lastPromptAt, exitCode, exitSignal, exitAt,
            disconnectReason, lastRequestId, importedFrom
        ]
        guard !fields.contains(.invalid), hasValidCore(raw), let conversation = conversation(raw) else {
            return nil
        }
        return object([
            ("schema", .text(SESSION_RECORD_SCHEMA)),
            ("acpxRecordId", raw["acpx_record_id"]),
            ("acpSessionId", raw["acp_session_id"]),
            ("agentSessionId", nonEmptyString(raw["agent_session_id"])),
            ("agentCommand", raw["agent_command"]),
            ("agentArgv", agentArgv(raw)),
            ("cwd", raw["cwd"]),
            ("name", name.value),
            ("createdAt", raw["created_at"]),
            ("lastUsedAt", raw["last_used_at"]),
            ("lastSeq", raw["last_seq"]),
            ("lastRequestId", lastRequestId.value),
            ("eventLog", eventLog(raw["event_log"], recordId: recordId)),
            ("closed", closed.value),
            ("closedAt", closedAt.value),
            ("pid", pid.value),
            ("agentStartedAt", agentStartedAt.value),
            ("lastPromptAt", lastPromptAt.value),
            ("lastAgentExitCode", exitCode.value),
            ("lastAgentExitSignal", exitSignal.value),
            ("lastAgentExitAt", exitAt.value),
            ("lastAgentDisconnectReason", disconnectReason.value),
            ("protocolVersion", raw["protocol_version"].flatMap { $0.isNumber ? $0 : nil }),
            ("agentCapabilities", raw["agent_capabilities"].flatMap { $0.isObject ? $0 : nil })
        ] + conversation + [
            ("acpx", acpxState(raw["acpx"])),
            ("importedFrom", importedFrom.value)
        ])
    }

    /// `hasValidSessionRecordCore`: the fields every record must have.
    static func hasValidCore(_ raw: WireJSON) -> Bool {
        let strings = ["acpx_record_id", "acp_session_id", "agent_command", "cwd", "created_at", "last_used_at"]
        guard strings.allSatisfy({ raw[$0]?.stringValue != nil }),
            case .number(let lastSeq)? = raw["last_seq"]
        else { return false }
        return isInteger(lastSeq) && lastSeq >= 0
    }

    // MARK: - Optional fields

    /// `normalizeOptionalName`: trimmed, and left out when that leaves nothing.
    static func optionalName(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        guard case .string(let units) = value else { return .invalid }
        let trimmed = javaScriptTrimmed(units)
        return trimmed.isEmpty ? .undefined : .kept(.string(trimmed))
    }

    /// `normalizeOptionalPid`: a positive integer.
    static func optionalPid(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        return isPositiveInteger(value) ? .kept(value) : .invalid
    }

    /// `normalizeOptionalBoolean(value, false)`: absent means `false`.
    static func optionalBoolean(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .kept(.bool(false)) }
        guard case .bool = value else { return .invalid }
        return .kept(value)
    }

    /// `normalizeOptionalString`.
    static func optionalString(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        guard case .string = value else { return .invalid }
        return .kept(value)
    }

    /// `normalizeOptionalExitCode`: an integer, or a `null` that is kept.
    static func optionalExitCode(_ value: WireJSON?) -> Parsed {
        guard let value else { return .undefined }
        if value == .null { return .kept(.null) }
        guard case .number(let number) = value, isInteger(number) else { return .invalid }
        return .kept(value)
    }

    /// `normalizeOptionalSignal`: a string, or a `null` that is kept.
    static func optionalSignal(_ value: WireJSON?) -> Parsed {
        guard let value else { return .undefined }
        if value == .null { return .kept(.null) }
        guard case .string = value else { return .invalid }
        return .kept(value)
    }

    /// `parseImportedFrom`: the four origin strings, renamed camelCase.
    static func importedFrom(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        let keys = [("record_id", "recordId"), ("cwd_original", "cwdOriginal"),
                    ("exported_by", "exportedBy"), ("exported_at", "exportedAt")]
        guard case .object = value, keys.allSatisfy({ value[$0.0]?.stringValue != nil }) else {
            return .invalid
        }
        return .kept(object(keys.map { ($0.1, value[$0.0]) }))
    }

    /// `normalizeAgentSessionId` / `parseNonEmptyString`: a string, trimmed, left out
    /// when that leaves nothing — and when it is not a string at all.
    static func nonEmptyString(_ value: WireJSON?) -> WireJSON? {
        guard case .string(let units)? = value else { return nil }
        let trimmed = javaScriptTrimmed(units)
        return trimmed.isEmpty ? nil : .string(trimmed)
    }

    // MARK: - Agent argv and event log

    /// `parsePersistedAgentArgv`: the stored argv, or the one acpx knows for a built-in
    /// command line the record names (`resolveAgentArgvForCommand`).
    static func agentArgv(_ raw: WireJSON) -> WireJSON? {
        if case .array(let items)? = raw["agent_argv"], !items.isEmpty,
            items.allSatisfy({ $0.stringValue != nil }), case .string(let first) = items[0], !first.isEmpty {
            return .array(items)
        }
        guard let command = raw["agent_command"]?.stringValue,
            let argv = builtInArgv(forCommand: command)
        else { return nil }
        return .array(argv.map(WireJSON.text))
    }

    /// `resolveAgentArgvForCommand`: the argv of the built-in agent `command` launches,
    /// under its current command line or one it had before.
    static func builtInArgv(forCommand command: String) -> [String]? {
        let name =
            AgentRegistry.ordered.first { $0.command == command }?.name
            ?? legacyCommands.first { $0.commands.contains(command) }?.name
        return name.flatMap { AgentRegistry.builtIn[$0] }.map { $0.split(separator: " ").map(String.init) }
    }

    /// acpx's `legacyFallbackCommands` and `LEGACY_AGENT_COMMANDS`: command lines built-in
    /// agents were launched with before, which records can still name.
    static let legacyCommands: [(name: String, commands: [String])] = [
        ("claude", ["npm exec @agentclientprotocol/claude-agent-acp@\(AgentRegistry.PackageRange.claude)"]),
        ("pi", ["npx pi-acp", "npx pi-acp@^0.0.22", "npx pi-acp@^0.0.26"]),
        ("codex", [
            "npx @zed-industries/codex-acp", "npx @zed-industries/codex-acp@^0.9.5",
            "npx @zed-industries/codex-acp@^0.10.0", "npx @zed-industries/codex-acp@^0.11.1",
            "npx @zed-industries/codex-acp@^0.12.0", "npx -y @agentclientprotocol/codex-acp@^0.0.44",
            "npx -y @agentclientprotocol/codex-acp@^1.1.4"
        ]),
        ("claude", [
            "npx @zed-industries/claude-agent-acp", "npx -y @zed-industries/claude-agent-acp",
            "npx -y @zed-industries/claude-agent-acp@^0.21.0", "npx -y @zed-industries/claude-agent-acp@^0.23.1",
            "npx -y @zed-industries/claude-agent-acp@^0.24.2", "npx -y @zed-industries/claude-agent-acp@^0.25.0",
            "npx -y @zed-industries/claude-agent-acp@^0.31.0", "npx -y @agentclientprotocol/claude-agent-acp@^0.36.1",
            "npx -y @agentclientprotocol/claude-agent-acp@^0.37.0",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.36.1",
            "npm exec @agentclientprotocol/claude-agent-acp@^0.37.0"
        ]),
        ("gemini", ["gemini", "gemini --experimental-acp"]),
        ("kiro", ["kiro-cli acp"]),
        ("mux", ["npx -y mux@^0.27.0 acp"]),
        ("opencode", ["npx opencode-ai"])
    ]

    /// `parseEventLog`: the stored log when its core is valid, else acpx's default.
    static func eventLog(_ value: WireJSON?, recordId: String) -> WireJSON {
        let sizes = ["segment_count", "max_segment_bytes", "max_segments"]
        guard let value, case .object = value, value["active_path"]?.stringValue != nil,
            sizes.allSatisfy({ value[$0].map(isPositiveInteger) == true })
        else {
            return object([
                ("active_path", .text(ACPXPaths.sessionStreamPath(recordId).path)),
                ("segment_count", .number(Double(DEFAULT_EVENT_MAX_SEGMENTS))),
                ("max_segment_bytes", .number(Double(DEFAULT_EVENT_SEGMENT_MAX_BYTES))),
                ("max_segments", .number(Double(DEFAULT_EVENT_MAX_SEGMENTS))),
                ("last_write_error", .null)
            ])
        }
        let lastWriteError: WireJSON?
        switch value["last_write_error"] {
        case nil: lastWriteError = nil
        case .null?, .string?: lastWriteError = value["last_write_error"]
        default: lastWriteError = .null
        }
        return object([
            ("active_path", value["active_path"]),
            ("segment_count", value["segment_count"]),
            ("max_segment_bytes", value["max_segment_bytes"]),
            ("max_segments", value["max_segments"]),
            ("last_write_at", value["last_write_at"].flatMap { $0.stringValue != nil ? $0 : nil }),
            ("last_write_error", lastWriteError)
        ])
    }

    // MARK: - For SwiftACP's model

    /// The stored record with acpx's reading of the fields it reads leniently — the ones
    /// it drops, defaults or trims rather than rejecting the record over — so SwiftACP's
    /// model reads every record acpx does, and reads it as acpx does: a name matches
    /// trimmed, an unreadable event log is the default one. Every other member,
    /// SwiftACP's own included, is left as stored.
    ///
    /// - Parameter parsed: what ``parse(_:)`` made of `raw`.
    public static func normalizedForModel(_ raw: WireJSON, parsed: WireJSON) -> WireJSON {
        guard case .object(let members) = raw else { return raw }
        var protocolVersion: WireJSON?
        if case .number(let version)? = parsed["protocolVersion"], isInteger(version) {
            protocolVersion = parsed["protocolVersion"]
        }
        let normalized: [String: WireJSON?] = [
            "name": parsed["name"],
            "agent_session_id": parsed["agentSessionId"],
            "event_log": parsed["eventLog"],
            "protocol_version": protocolVersion,
            "agent_capabilities": parsed["agentCapabilities"],
            "cumulative_token_usage": parsed["cumulative_token_usage"],
            "cumulative_cost": parsed["cumulative_cost"],
            "request_token_usage": parsed["request_token_usage"],
            // A block that does not read at all may have held restrictions: it fails closed.
            "acpx": parsed["acpx"].map { withOwnFields($0, from: raw["acpx"]) }
                ?? (raw["acpx"] == nil ? nil : unreadableAcpxState)
        ]
        return .object(members.compactMap { member in
            guard let replacement = normalized[String(decoding: member.key, as: UTF16.self)] else {
                return member
            }
            return replacement.map { WireJSON.Member(key: member.key, value: $0) }
        })
    }

    /// What an `acpx` block that is there but is no object leaves SwiftACP's model with:
    /// its own restrictions at their tightest — no MCP servers and no client
    /// capabilities — since the block may have held some. acpx drops such a block.
    static let unreadableAcpxState = object([
        ("mcp_servers", .array([])),
        ("client_capabilities", object([
            ("read_text_file", .bool(false)), ("write_text_file", .bool(false)), ("terminal", .bool(false))
        ]))
    ])

    /// The `acpx` fields acpx reads (`SessionAcpxState`).
    static let acpxStateKeys: Set<String> = [
        "reset_on_next_ensure", "current_mode_id", "desired_mode_id", "desired_config_options",
        "current_model_id", "available_models", "available_model_names", "model_control",
        "available_commands", "config_options", "session_options"
    ]

    /// acpx's reading of the `acpx` block, followed by the stored fields it does not
    /// read — SwiftACP's own.
    static func withOwnFields(_ state: WireJSON, from stored: WireJSON?) -> WireJSON {
        guard case .object(let read) = state, case .object(let members)? = stored else { return state }
        let own = members.filter { !acpxStateKeys.contains(String(decoding: $0.key, as: UTF16.self)) }
        return .object(read + own)
    }

    // MARK: - Helpers

    /// An object with these members in this order, leaving out a `nil` one as
    /// `JSON.stringify` leaves out an `undefined` property.
    static func object(_ members: [(String, WireJSON?)]) -> WireJSON {
        .object(members.compactMap { key, value in value.map { WireJSON.Member(key, $0) } })
    }

    /// `Number.isInteger`.
    static func isInteger(_ number: Double) -> Bool {
        number.isFinite && number.rounded(.towardZero) == number
    }

    /// `isPositiveInteger`.
    static func isPositiveInteger(_ value: WireJSON) -> Bool {
        guard case .number(let number) = value else { return false }
        return isInteger(number) && number > 0
    }

    /// `String.prototype.trim` on the string's UTF-16 code units, so a lone surrogate
    /// survives as it does in JavaScript.
    static func javaScriptTrimmed(_ units: [UInt16]) -> [UInt16] {
        guard let first = units.firstIndex(where: { !isJavaScriptWhitespace($0) }),
            let last = units.lastIndex(where: { !isJavaScriptWhitespace($0) })
        else { return [] }
        return Array(units[first...last])
    }

    /// JavaScript's whitespace and line terminators — every one a single code unit.
    static func isJavaScriptWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
}

extension WireJSON {
    /// This value with each lone surrogate, in strings and keys alike, made U+FFFD —
    /// what a Swift `String` makes of it. JavaScript writes a lone surrogate's escape and
    /// reads it back; Foundation's `JSONDecoder` refuses it.
    public func replacingLoneSurrogates() -> WireJSON {
        switch self {
        case .string(let units): return .string(Self.replacingLoneSurrogates(units))
        case .array(let items): return .array(items.map { $0.replacingLoneSurrogates() })
        case .object(let members):
            return .object(members.map {
                Member(key: Self.replacingLoneSurrogates($0.key), value: $0.value.replacingLoneSurrogates())
            })
        default: return self
        }
    }

    private static func replacingLoneSurrogates(_ units: [UInt16]) -> [UInt16] {
        guard units.contains(where: { (0xD800...0xDFFF).contains($0) }) else { return units }
        var result = units
        var index = 0
        while index < result.count {
            let unit = result[index]
            let pairsWithNext = index + 1 < result.count && (0xDC00...0xDFFF).contains(result[index + 1])
            if (0xD800...0xDBFF).contains(unit), pairsWithNext {
                index += 2
                continue
            }
            if (0xD800...0xDFFF).contains(unit) { result[index] = 0xFFFD }
            index += 1
        }
        return result
    }

    var isNumber: Bool {
        if case .number = self { return true }
        return false
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}
