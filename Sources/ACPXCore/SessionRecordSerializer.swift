import Foundation
import SwiftACP

/// How acpx writes a session record: `JSON.stringify(serializeSessionRecordForDisk(record),
/// null, 2)` and a newline (`src/session/persistence/serialize.ts`).
///
/// acpx serializes its in-memory record, which is what its parser made of the file
/// (``SessionRecordParser/parse(_:)``), changed by what happened since: the top level in
/// the serializer's order, and each nested object in the order it was built. SwiftACP
/// writes its record the same way, then adds back after acpx's `acpx` fields its own
/// ones, which acpx's parser does not read (``SessionRecordParser/withOwnFields(_:from:)``).
///
/// Where the model has lost an order — its encoder sorts members — the file takes it from
/// where acpx has it: a message as acpx's conversation model builds one, and anything the
/// record was read with as it was read (``inStoredOrder(_:stored:topLevel:)``).
enum SessionRecordSerializer {
    /// The file for `record`, as acpx would write it. A record acpx would not take at all
    /// is written whole, as SwiftACP encodes it, so nothing of it is lost.
    static func data(for record: SessionRecord) throws -> Data {
        let encoded = try recordDiskEncoder.encode(record)
        guard let raw = WireJSON(parsing: encoded) else { return encoded + Data("\n".utf8) }
        guard let parsed = SessionRecordParser.parse(raw) else {
            return Data((raw.stringified(indent: 2) + "\n").utf8)
        }
        let rebuilt = record.acpx?.rebuiltOrders ?? [:]
        let built = parsed
            .mapping("messages") { $0.mappingItems(MessageOrder.built) }
            .mapping("request_token_usage") { MessageOrder.requestTokenUsage($0, of: record) }
            .mapping("acpx") { acpx in
                rebuilt.reduce(acpx) { acpx, map in acpx.mapping(map.key) { MessageOrder.ordered($0, by: map.value) } }
            }
        var document = forDisk(built, storedAcpx: raw["acpx"])
        if let stored = record.parsedByAcpx {
            let read = forDisk(stored, storedAcpx: nil)
                .mapping("messages") { MessageOrder.aligned($0, trimmed: record.messagesTrimmedSinceRead) }
            document = inStoredOrder(
                document, stored: read, topLevel: true, rebuilt: Set(rebuilt.keys.map { Array($0.utf16) }))
        }
        if let acpx = record.acpx {
            // The block's members in the places acpx's object gives them (``SessionAcpxState/slots``),
            // SwiftACP's own after; `session_options` as acpx always builds it.
            document = document.mapping("acpx") { block in
                MessageOrder.ordered(block, by: acpx.slots).mapping("session_options") {
                    MessageOrder.ordered($0, by: ["model", "allowed_tools", "max_turns", "system_prompt", "env"])
                }
            }
        }
        return Data((document.stringified(indent: 2) + "\n").utf8)
    }

    /// acpx's `serializeSessionRecordForDisk` of the in-memory record `parsed`, with
    /// SwiftACP's own fields of `storedAcpx` after acpx's `acpx` fields.
    static func forDisk(_ parsed: WireJSON, storedAcpx: WireJSON?) -> WireJSON {
        SessionRecordParser.object([
            ("schema", parsed["schema"]),
            ("acpx_record_id", parsed["acpxRecordId"]),
            ("acp_session_id", parsed["acpSessionId"]),
            ("agent_session_id", agentSessionId(parsed["agentSessionId"])),
            ("agent_command", parsed["agentCommand"]),
            ("agent_argv", parsed["agentArgv"]),
            ("cwd", parsed["cwd"]),
            ("name", parsed["name"]),
            ("created_at", parsed["createdAt"]),
            ("last_used_at", parsed["lastUsedAt"]),
            ("last_seq", parsed["lastSeq"]),
            ("last_request_id", parsed["lastRequestId"]),
            ("event_log", parsed["eventLog"]),
            ("closed", parsed["closed"]),
            ("closed_at", parsed["closedAt"]),
            ("pid", parsed["pid"]),
            ("agent_started_at", parsed["agentStartedAt"]),
            ("last_prompt_at", parsed["lastPromptAt"]),
            ("last_agent_exit_code", parsed["lastAgentExitCode"]),
            ("last_agent_exit_signal", parsed["lastAgentExitSignal"]),
            ("last_agent_exit_at", parsed["lastAgentExitAt"]),
            ("last_agent_disconnect_reason", parsed["lastAgentDisconnectReason"]),
            ("protocol_version", parsed["protocolVersion"]),
            ("agent_capabilities", parsed["agentCapabilities"]),
            ("title", parsed["title"]),
            ("messages", parsed["messages"]),
            ("updated_at", parsed["updated_at"]),
            ("cumulative_token_usage", parsed["cumulative_token_usage"]),
            ("cumulative_cost", parsed["cumulative_cost"]),
            ("request_token_usage", parsed["request_token_usage"]),
            ("acpx", parsed["acpx"].map { SessionRecordParser.withOwnFields($0, from: storedAcpx) }),
            ("imported_from", importedFrom(parsed["importedFrom"]))
        ])
    }

    /// `value`, a record's file or part of it, in the order of `stored`, what the record
    /// was read with: the stored value itself where the two are the same, and otherwise
    /// an object's members in their stored order, followed by those it lacked — as an
    /// object acpx read and then changed keeps its members' places and adds new ones last.
    /// The file's top level keeps its own order: acpx's serializer builds it anew.
    ///
    /// An array that changed pairs its items with the stored ones only where an item is
    /// what was stored at its place: in the messages (lined up by ``MessageOrder/aligned(_:trimmed:)``)
    /// and the lists of their content, which only grow. Anywhere else a changed array was
    /// replaced whole, as acpx replaces `config_options`, and keeps the order it has — as
    /// does what the agent sent within a message, a tool's input or output, once it
    /// changed: acpx replaces that whole too. So does a map of the `acpx` block that
    /// acpx built anew since the record was read, `rebuilt` (the block's
    /// `rebuiltOrders`): it is as built, in the order acpx gave it.
    ///
    /// Only the order changes: whatever is taken from `stored` is equal to what it
    /// stands in for.
    static func inStoredOrder(
        _ value: WireJSON, stored: WireJSON, topLevel: Bool = false, inMessages: Bool = false,
        rebuilt: Set<[UInt16]> = []
    ) -> WireJSON {
        switch (value, stored) {
        case (.object(let members), .object(let storedMembers)):
            if !topLevel, rebuilt.isEmpty, sameValue(value, stored) { return stored }
            let storedValues = Dictionary(storedMembers.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            let changed = members.map { member in
                let kept = storedValues[member.key].map { storedValue in
                    if inMessages, agentPayloads.contains(member.key) {
                        return sameValue(member.value, storedValue) ? storedValue : member.value
                    }
                    if !topLevel, rebuilt.contains(member.key) { return member.value }
                    let inMessages = inMessages || (topLevel && member.key == Array("messages".utf16))
                    let rebuilt = topLevel && member.key == Array("acpx".utf16) ? rebuilt : []
                    return inStoredOrder(member.value, stored: storedValue, inMessages: inMessages, rebuilt: rebuilt)
                }
                return WireJSON.Member(key: member.key, value: kept ?? member.value)
            }
            guard !topLevel else { return .object(changed) }
            let values = Dictionary(changed.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            let kept = storedMembers.compactMap { member in
                values[member.key].map { WireJSON.Member(key: member.key, value: $0) }
            }
            return .object(kept + changed.filter { storedValues[$0.key] == nil })
        case (.array(let items), .array(let storedItems)):
            if sameValue(value, stored) { return stored }
            guard inMessages else { return value }
            return .array(items.enumerated().map { index, item in
                index < storedItems.count ? inStoredOrder(item, stored: storedItems[index], inMessages: true) : item
            })
        default:
            return value
        }
    }

    /// The members of a message that hold what the agent sent: a tool use's input and a
    /// tool result's output.
    private static let agentPayloads: Set<[UInt16]> = [Array("input".utf16), Array("output".utf16)]

    /// Whether `a` and `b` are the same JSON value, whatever order their objects list
    /// their members in.
    static func sameValue(_ a: WireJSON, _ b: WireJSON) -> Bool {
        switch (a, b) {
        case (.object(let members), .object(let others)):
            guard members.count == others.count else { return false }
            let values = Dictionary(others.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            return members.allSatisfy { member in values[member.key].map { sameValue(member.value, $0) } ?? false }
        case (.array(let items), .array(let others)):
            return items.count == others.count && zip(items, others).allSatisfy { sameValue($0, $1) }
        default:
            return a == b
        }
    }

    /// acpx's `normalizeAgentSessionId`: a string, trimmed, and only if something is left.
    private static func agentSessionId(_ value: WireJSON?) -> WireJSON? {
        guard let id = value?.stringValue else { return nil }
        let trimmed = id.javaScriptTrimmed
        return trimmed.isEmpty ? nil : .text(trimmed)
    }

    /// The serializer's `imported_from`: the provenance's fields, snake_cased.
    private static func importedFrom(_ value: WireJSON?) -> WireJSON? {
        guard let value, case .object = value else { return nil }
        return SessionRecordParser.object([
            ("record_id", value["recordId"]),
            ("cwd_original", value["cwdOriginal"]),
            ("exported_by", value["exportedBy"]),
            ("exported_at", value["exportedAt"])
        ])
    }
}

/// The order acpx's conversation model builds a message's members in
/// (`src/session/conversation-model.ts`). Members it does not build keep their order,
/// after those it does.
enum MessageOrder {
    /// `message` — `"Resume"`, `{"User": …}` or `{"Agent": …}` — in that order.
    static func built(_ message: WireJSON) -> WireJSON {
        message
            .mapping("User") { user in
                user.ordered(["id", "content"]).mapping("content") { $0.mappingItems(userContent) }
            }
            .mapping("Agent") { agent in
                agent.ordered(["content", "tool_results"])
                    .mapping("content") { $0.mappingItems(agentContent) }
                    .mapping("tool_results") { toolResults($0, in: agent["content"]) }
            }
    }

    /// `contentToUserContent`'s variants.
    private static func userContent(_ content: WireJSON) -> WireJSON {
        content
            .mapping("Mention") { $0.ordered(["uri", "content"]) }
            .mapping("Image") { image in
                image.ordered(["source", "mime_type", "size"]).mapping("size") { $0.ordered(["width", "height"]) }
            }
            .mapping("Audio") { $0.ordered(["source", "mime_type"]) }
    }

    /// `appendAgentThinking`'s and `ensureToolUseContent`'s.
    private static func agentContent(_ content: WireJSON) -> WireJSON {
        content
            .mapping("Thinking") { $0.ordered(["text", "signature"]) }
            .mapping("ToolUse") {
                $0.ordered(["id", "name", "raw_input", "input", "is_input_complete", "thought_signature"])
            }
    }

    /// `upsertToolResult`'s results, in the order the agent's tool uses came in: acpx adds
    /// each tool's result with its first update, which also adds its tool use.
    private static func toolResults(_ results: WireJSON, in content: WireJSON?) -> WireJSON {
        var position: [[UInt16]: Int] = [:]
        for case .string(let id)? in items(of: content).map({ $0["ToolUse"]?["id"] }) where position[id] == nil {
            position[id] = position.count
        }
        return sorted(results) { position[$0] ?? Int.max }
            .mappingMembers { $0.ordered(["tool_use_id", "tool_name", "is_error", "content", "output"]) }
    }

    /// `stored`, the messages a record was read with, lined up with those it holds now,
    /// each with itself: a turn only adds messages, and trimming drops the oldest
    /// (`trimConversationForRuntime`) — `trimmed` of them since the record was read.
    static func aligned(_ stored: WireJSON, trimmed: Int) -> WireJSON {
        .array(Array(items(of: stored).dropFirst(trimmed)))
    }

    /// `object`'s members in `order`, then any others as they were.
    static func ordered(_ object: WireJSON, by order: [String]) -> WireJSON {
        var position: [[UInt16]: Int] = [:]
        for (index, key) in order.enumerated() where position[Array(key.utf16)] == nil {
            position[Array(key.utf16)] = index
        }
        return sorted(object) { position[$0] ?? Int.max }
    }

    /// `request_token_usage` in the order acpx's object holds its entries: the order it
    /// got them in (``ConversationModel/requestUsageOrder(_:)``).
    static func requestTokenUsage(_ usage: WireJSON, of record: SessionRecord) -> WireJSON {
        let order = ConversationModel.requestUsageOrder(record)
        return sorted(usage) { order(String(decoding: $0, as: UTF16.self)) }
    }

    private static func items(of array: WireJSON?) -> [WireJSON] {
        guard case .array(let items)? = array else { return [] }
        return items
    }

    /// `object`'s members by the place `position` gives each name, those given the same
    /// place as they were.
    private static func sorted(_ object: WireJSON, by position: ([UInt16]) -> Int) -> WireJSON {
        guard case .object(let members) = object else { return object }
        return .object(members.enumerated().sorted { lhs, rhs in
            let (left, right) = (position(lhs.element.key), position(rhs.element.key))
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element))
    }
}

extension WireJSON {
    /// This object with `keys`' members first, in that order, then the others as they
    /// were. Anything else is unchanged.
    fileprivate func ordered(_ keys: [String]) -> WireJSON {
        guard case .object(let members) = self else { return self }
        let wanted = keys.map { Array($0.utf16) }
        let first = wanted.compactMap { key in members.first { $0.key == key } }
        return .object(first + members.filter { !wanted.contains($0.key) })
    }

    /// This object with `key`'s value transformed in place. Unchanged when absent.
    fileprivate func mapping(_ key: String, _ transform: (WireJSON) -> WireJSON) -> WireJSON {
        self[key].map { replacing(key, with: transform($0)) } ?? self
    }

    /// This array with each item transformed. Anything else is unchanged.
    fileprivate func mappingItems(_ transform: (WireJSON) -> WireJSON) -> WireJSON {
        guard case .array(let items) = self else { return self }
        return .array(items.map(transform))
    }

    /// This object with each member's value transformed. Anything else is unchanged.
    fileprivate func mappingMembers(_ transform: (WireJSON) -> WireJSON) -> WireJSON {
        guard case .object(let members) = self else { return self }
        return .object(members.map { WireJSON.Member(key: $0.key, value: transform($0.value)) })
    }
}
