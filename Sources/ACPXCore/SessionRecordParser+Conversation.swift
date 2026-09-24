import Foundation

// The conversation half of acpx's `parseSessionRecord`: the messages must all be valid
// Zed-format messages, and the token usage and cost are rebuilt from the counters and
// fields acpx knows. Any of them invalid makes the whole record invalid.
//
// Split from `SessionRecordParser.swift` to keep each file inside the 500-line limit.
extension SessionRecordParser {
    /// `parseConversationRecord`: the conversation's members, in acpx's order, or `nil`
    /// when they make the record invalid.
    static func conversation(_ raw: WireJSON) -> [(String, WireJSON?)]? {
        guard case .array(let messages)? = raw["messages"], messages.allSatisfy(isConversationMessage),
            raw["updated_at"]?.stringValue != nil
        else { return nil }
        let title: WireJSON?
        switch raw["title"] {
        case nil: title = nil
        case .null?, .string?: title = raw["title"]
        default: return nil
        }
        let usage = tokenUsage(raw["cumulative_token_usage"])
        let cost = usageCost(raw["cumulative_cost"])
        let requestUsage = requestTokenUsage(raw["request_token_usage"])
        guard usage != .invalid, cost != .invalid, requestUsage != .invalid else { return nil }
        return [
            ("title", title),
            ("messages", raw["messages"]),
            ("updated_at", raw["updated_at"]),
            ("cumulative_token_usage", usage.value ?? .object([])),
            ("cumulative_cost", cost.value),
            ("request_token_usage", requestUsage.value ?? .object([]))
        ]
    }

    // MARK: - Token usage and cost

    /// `parseTokenUsage`: the counters acpx knows, in its order — each a non-negative
    /// finite number.
    static func tokenUsage(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        guard case .object = value else { return .invalid }
        let counters = [
            "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
            "thought_tokens", "total_tokens"
        ]
        var usage: [(String, WireJSON?)] = []
        for counter in counters {
            guard let count = value[counter] else { continue }
            guard isNonNegativeFinite(count) else { return .invalid }
            usage.append((counter, count))
        }
        return .kept(object(usage))
    }

    /// `parseUsageCost`: the amount and the currency (trimmed), left out when neither
    /// is there.
    static func usageCost(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        guard case .object = value else { return .invalid }
        var amount: WireJSON?
        if let given = value["amount"] {
            guard isNonNegativeFinite(given) else { return .invalid }
            amount = given
        }
        var currency: WireJSON?
        if let given = value["currency"] {
            guard case .string(let units) = given else { return .invalid }
            let trimmed = javaScriptTrimmed(units)
            currency = trimmed.isEmpty ? nil : .string(trimmed)
        }
        guard amount != nil || currency != nil else { return .undefined }
        return .kept(object([("amount", amount), ("currency", currency)]))
    }

    /// `parseRequestTokenUsage`: each request's usage, parsed as `parseTokenUsage`
    /// does; one that is missing or invalid makes the whole map invalid.
    static func requestTokenUsage(_ value: WireJSON?) -> Parsed {
        guard let value, value != .null else { return .undefined }
        guard case .object(let requests) = value else { return .invalid }
        var usage: [WireJSON.Member] = []
        for request in requests {
            guard case .kept(let parsed) = tokenUsage(request.value) else { return .invalid }
            usage.append(WireJSON.Member(key: request.key, value: parsed))
        }
        return .kept(.object(usage))
    }

    /// `isNonNegativeFiniteNumber`.
    static func isNonNegativeFinite(_ value: WireJSON) -> Bool {
        guard case .number(let number) = value else { return false }
        return number.isFinite && number >= 0
    }

    // MARK: - Messages

    /// `isConversationMessage`: `"Resume"`, a user message or an agent message.
    static func isConversationMessage(_ message: WireJSON) -> Bool {
        message == .text("Resume") || isUserMessage(message) || isAgentMessage(message)
    }

    /// `isUserMessage`: an id, and content that is all valid user content.
    static func isUserMessage(_ message: WireJSON) -> Bool {
        guard case .object = message, let user = message["User"], case .object = user,
            user["id"]?.stringValue != nil, case .array(let content)? = user["content"]
        else { return false }
        return content.allSatisfy(isUserContent)
    }

    /// `isUserContent`: text, a mention, an image or an audio clip.
    static func isUserContent(_ content: WireJSON) -> Bool {
        guard case .object = content else { return false }
        if content["Text"]?.stringValue != nil { return true }
        if let mention = content["Mention"] {
            return mention["uri"]?.stringValue != nil && mention["content"]?.stringValue != nil
        }
        if let image = content["Image"] { return isImage(image) }
        if let audio = content["Audio"] {
            return audio["source"]?.stringValue != nil && audio["mime_type"]?.stringValue != nil
        }
        return false
    }

    /// `isSessionMessageImage`: a source, and a size (when given) of finite numbers.
    static func isImage(_ image: WireJSON) -> Bool {
        guard case .object = image, image["source"]?.stringValue != nil else { return false }
        guard let size = image["size"], size != .null else { return true }
        guard case .object = size, case .number(let width)? = size["width"],
            case .number(let height)? = size["height"]
        else { return false }
        return width.isFinite && height.isFinite
    }

    /// `isAgentMessage`: content that is all valid agent content, and tool results
    /// that are all valid.
    static func isAgentMessage(_ message: WireJSON) -> Bool {
        guard case .object = message, let agent = message["Agent"], case .object = agent,
            case .array(let content)? = agent["content"], content.allSatisfy(isAgentContent),
            case .object(let results)? = agent["tool_results"]
        else { return false }
        return results.allSatisfy { isToolResult($0.value) }
    }

    /// `isAgentContent`: text, thinking, redacted thinking or a tool use.
    static func isAgentContent(_ content: WireJSON) -> Bool {
        guard case .object = content else { return false }
        if content["Text"]?.stringValue != nil { return true }
        if let thinking = content["Thinking"] {
            guard case .object = thinking, thinking["text"]?.stringValue != nil else { return false }
            return isOptionalString(thinking["signature"])
        }
        if content["RedactedThinking"]?.stringValue != nil { return true }
        if let toolUse = content["ToolUse"] { return isToolUse(toolUse) }
        return false
    }

    /// `isToolUse`.
    static func isToolUse(_ toolUse: WireJSON) -> Bool {
        guard case .object = toolUse,
            ["id", "name", "raw_input"].allSatisfy({ toolUse[$0]?.stringValue != nil }),
            toolUse.hasMember("input"), case .bool? = toolUse["is_input_complete"]
        else { return false }
        return isOptionalString(toolUse["thought_signature"])
    }

    /// `isToolResult`: its content is text or an image.
    static func isToolResult(_ result: WireJSON) -> Bool {
        guard case .object = result, result["tool_use_id"]?.stringValue != nil,
            result["tool_name"]?.stringValue != nil, case .bool? = result["is_error"],
            let content = result["content"], case .object = content
        else { return false }
        if content["Text"]?.stringValue != nil { return true }
        if let image = content["Image"] { return isImage(image) }
        return false
    }

    // MARK: - The conversation as the model reads it

    /// The messages as SwiftACP's model reads them. Each message, and each piece of its
    /// content, is reduced to the variant acpx's checks accepted it as — the first, in
    /// their order — so a wrong-typed member ahead of it cannot fail the model's
    /// decoding of a record acpx reads.
    static func modelMessages(_ messages: WireJSON?) -> WireJSON? {
        guard case .array(let list)? = messages else { return messages }
        return .array(list.map(modelMessage))
    }

    static func modelMessage(_ message: WireJSON) -> WireJSON {
        if isUserMessage(message), let user = message["User"], case .array(let content)? = user["content"] {
            return object([("User", user.replacing("content", with: .array(content.map(modelUserContent))))])
        }
        if isAgentMessage(message), let agent = message["Agent"], case .array(let content)? = agent["content"] {
            return object([("Agent", agent.replacing("content", with: .array(content.map(modelAgentContent))))])
        }
        return message
    }

    /// ``isUserContent(_:)``'s choice: text when it is a string, else whichever of a
    /// mention, an image or an audio clip comes first. An image's `mime_type`, which
    /// only SwiftACP writes, stays only when it is a string.
    static func modelUserContent(_ content: WireJSON) -> WireJSON {
        if let text = content["Text"], text.stringValue != nil { return object([("Text", text)]) }
        if let mention = content["Mention"] { return object([("Mention", mention)]) }
        if let image = content["Image"] {
            let unreadableMimeType = image["mime_type"].map { $0.stringValue == nil } ?? false
            return object([("Image", unreadableMimeType ? image.removing("mime_type") : image)])
        }
        if let audio = content["Audio"] { return object([("Audio", audio)]) }
        return content
    }

    /// ``isAgentContent(_:)``'s choice: text when it is a string, else thinking, else
    /// redacted thinking when it is a string, else a tool use.
    static func modelAgentContent(_ content: WireJSON) -> WireJSON {
        if let text = content["Text"], text.stringValue != nil { return object([("Text", text)]) }
        if let thinking = content["Thinking"] { return object([("Thinking", thinking)]) }
        if let redacted = content["RedactedThinking"], redacted.stringValue != nil {
            return object([("RedactedThinking", redacted)])
        }
        if let toolUse = content["ToolUse"] { return object([("ToolUse", toolUse)]) }
        return content
    }

    /// `isOptionalString`: absent, `null` or a string.
    static func isOptionalString(_ value: WireJSON?) -> Bool {
        switch value {
        case nil, .null?, .string?: return true
        default: return false
        }
    }
}
