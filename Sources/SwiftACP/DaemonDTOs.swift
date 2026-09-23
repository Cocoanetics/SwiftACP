import Foundation
import JSONFoundation

// The acpx daemon's MCP tool DTOs — the structured wire types the `acpx` MCP server
// accepts, returns and streams. They live in this shared, iOS-capable library (rather
// than the macOS-only `ACPXCore`) so the generated `ACPXDaemon.Client` and an iOS MCP
// client can encode/decode them. `ACPXCore` adds the `init(record:)` convenience
// initializers that map a persisted `SessionRecord` into these.

/// An MCP server entry in acpx's *config* shape — the flat stdio / http / sse union
/// that `mcpServers` takes in `~/.acpx/config.json`, `.acpxrc.json` and `--mcp-config`
/// files (npm acpx's `McpServerConfig`), and that the daemon's `newSession` /
/// `setSessionMcpServers` tools accept per session.
///
/// It is deliberately a flat struct rather than the ACP wire enum ``MCPServerSpec``:
/// an MCP tool parameter needs a JSON schema (`@Schema`), which only structs get, and
/// callers should be able to omit `args` / `env` the way a config file can. `ACPXCore`
/// normalizes it to the wire shape (`McpServerConfig.protocolSpec()`).
@Schema
public struct McpServerConfig: Codable, Hashable, Sendable {
    /// The transport: `stdio` (the default when omitted), `http`, or `sse`.
    public var type: String?
    /// The server's name, as the agent lists it.
    public var name: String
    /// stdio: the executable the agent spawns.
    public var command: String?
    /// stdio: arguments for `command`.
    public var args: [String]?
    /// stdio: environment variables for the spawned server.
    public var env: [EnvEntry]?
    /// http / sse: the server URL.
    public var url: String?
    /// http / sse: HTTP headers to send.
    public var headers: [EnvEntry]?
    /// Optional `_meta` object, forwarded to the agent verbatim.
    public var meta: [String: JSONValue]?

    /// A name/value pair, used for both `env` (stdio) and `headers` (http/sse).
    @Schema
    public struct EnvEntry: Codable, Hashable, Sendable {
        /// The variable / header name.
        public var name: String
        /// Its value.
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, name, command, args, env, url, headers
        case meta = "_meta"
    }

    public init(
        type: String? = nil, name: String, command: String? = nil, args: [String]? = nil,
        env: [EnvEntry]? = nil, url: String? = nil, headers: [EnvEntry]? = nil,
        meta: [String: JSONValue]? = nil
    ) {
        self.type = type
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.meta = meta
    }
}

/// An image attached to a `runPrompt` turn, carried inline as base64.
///
/// Images only, deliberately. Both shipped adapters advertise
/// `promptCapabilities.image` and map an ACP `image` block onto their model's native
/// image input, but neither does anything useful with a *non-image* binary:
/// `claude-agent-acp` drops an embedded `resource` blob outright, and `codex-acp`
/// inlines its base64 into the prompt text, where it costs tokens and the model
/// answers from surrounding context instead of erroring. Refusing those here beats
/// forwarding them into a silent wrong answer. To hand an agent a PDF or any other
/// file, name its path in the prompt text and let the agent open it with its own
/// tools — that is what both adapters reduce a `resource_link` to anyway.
@Schema
public struct PromptAttachment: Codable, Hashable, Sendable {
    /// The image's MIME type: `image/png`, `image/jpeg`, `image/gif` or `image/webp`.
    public var mimeType: String
    /// The image itself, base64-encoded — the bare payload, no `data:` URI prefix.
    public var data: String

    public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }
}

extension PromptAttachment {
    /// The image types the agents' models actually accept. Stricter than ACP (which
    /// gates only on `promptCapabilities.image`) and stricter than npm acpx (which
    /// checks the `image/` prefix and nothing more), because neither adapter
    /// validates: an `image/bmp` sails through both and fails at the model instead.
    public static let supportedMimeTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Ceiling on the whole `runPrompt` request as it travels.
    ///
    /// The daemon's own TCP/Bonjour transport is newline-framed and caps nothing, but
    /// a turn should be servable over either transport, so this is the 4 MiB
    /// `maxMessageSize` that SwiftMCP's HTTP-SSE transport does enforce.
    ///
    /// Measured against the *encoded* payload, not the bytes it decodes to: base64
    /// inflates by 4/3, so a decoded ceiling of 3 MiB is exactly 4 MiB on the wire
    /// and leaves nothing for the request around it.
    public static let maxRequestBytes = 4 * 1024 * 1024

    /// Slack held back from ``maxRequestBytes`` for the JSON-RPC envelope we cannot
    /// measure here — method name, session id, field names, quoting — and for any
    /// escaping the prompt text picks up on the way into JSON. Base64 needs none: its
    /// alphabet survives JSON quoting byte for byte.
    static let envelopeReserve = 8 * 1024

    /// Validate `attachments` and turn the turn's `text` + images into ACP content
    /// blocks, in that order (text first, as npm acpx's `toPromptInput` does).
    ///
    /// Empty text contributes no block, so an image-only turn is possible; an empty
    /// prompt overall is rejected, since every agent errors on one anyway.
    public static func promptBlocks(
        text: String, attachments: [PromptAttachment]?
    ) throws -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }

        // Size the request the way the transport will: the base64 as sent, plus the
        // text it travels with, plus slack for the envelope around them.
        var requestBytes = text.utf8.count + envelopeReserve
        for (index, attachment) in (attachments ?? []).enumerated() {
            guard supportedMimeTypes.contains(attachment.mimeType.lowercased()) else {
                throw PromptAttachmentError.unsupportedMimeType(
                    index: index, mimeType: attachment.mimeType)
            }
            // Reject padding-less / whitespace-wrapped payloads too: the adapters pass
            // base64 straight through, so anything we let past fails at the model.
            guard let decoded = Data(base64Encoded: attachment.data), !decoded.isEmpty else {
                throw PromptAttachmentError.invalidBase64(index: index)
            }
            requestBytes += attachment.data.utf8.count + attachment.mimeType.utf8.count
            guard requestBytes <= maxRequestBytes else {
                throw PromptAttachmentError.tooLarge(
                    requestBytes: requestBytes, limit: maxRequestBytes)
            }
            blocks.append(
                .image(ImageContent(data: attachment.data, mimeType: attachment.mimeType)))
        }

        guard !blocks.isEmpty else { throw PromptAttachmentError.emptyPrompt }
        return blocks
    }
}

/// Why a turn's attachments were refused before reaching the agent.
public enum PromptAttachmentError: LocalizedError, Equatable {
    case unsupportedMimeType(index: Int, mimeType: String)
    case invalidBase64(index: Int)
    case tooLarge(requestBytes: Int, limit: Int)
    case emptyPrompt
    /// The agent's `initialize` did not advertise `promptCapabilities.image`.
    case imagesUnsupported(agent: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMimeType(let index, let mimeType):
            return """
                attachments[\(index)]: unsupported mimeType "\(mimeType)" — \
                runPrompt takes images only \
                (\(PromptAttachment.supportedMimeTypes.joined(separator: ", "))). \
                To share a PDF or other file, name its path in the prompt text and let \
                the agent open it.
                """
        case .invalidBase64(let index):
            return "attachments[\(index)]: data must be non-empty, unwrapped base64"
        case .tooLarge(let requestBytes, let limit):
            return """
                prompt and attachments exceed the per-turn limit: \(requestBytes) bytes \
                encoded, limit \(limit)
                """
        case .emptyPrompt:
            return "prompt must have text, attachments, or both"
        case .imagesUnsupported(let agent):
            return """
                agent "\(agent)" does not advertise promptCapabilities.image, \
                so it cannot accept image attachments
                """
        }
    }
}

/// The turn's terminal event, streamed as a final MCP log notification.
///
/// The `runPrompt` tool result is the agent's aggregate response *text* (so an MCP
/// client gets the actual answer, not a status token). The stop reason is therefore
/// demoted to a streamed event: the daemon sends one ``TurnEndedEvent`` once the turn
/// ends, right after the last `session/update` and before the tool returns.
public struct TurnEndedEvent: Codable, Sendable {
    /// The raw ACP stop reason (e.g. `end_turn`, `refusal`, `cancelled`).
    public var stopReason: String

    public init(stopReason: String) {
        self.stopReason = stopReason
    }
}

/// One row of the daemon's `listSessions` result — the columns the CLI's
/// `sessions list` shows, as structured data.
public struct SessionSummary: Codable, Sendable {
    public var id: String
    public var sessionId: String
    public var agentCommand: String
    public var cwd: String
    public var name: String?
    public var closed: Bool
    public var lastUsedAt: String

    public init(
        id: String, sessionId: String, agentCommand: String, cwd: String,
        name: String?, closed: Bool, lastUsedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentCommand = agentCommand
        self.cwd = cwd
        self.name = name
        self.closed = closed
        self.lastUsedAt = lastUsedAt
    }
}

/// The daemon's `showSession` result — the fields the CLI's `sessions show`
/// prints, as structured data.
public struct SessionDetail: Codable, Sendable {
    public var id: String
    public var sessionId: String
    public var agentSessionId: String?
    public var agentCommand: String
    public var cwd: String
    public var name: String?
    public var createdAt: String
    public var lastUsedAt: String
    public var lastPromptAt: String?
    public var closed: Bool
    public var closedAt: String?
    public var pid: Int?
    public var agentStartedAt: String?
    public var lastAgentExitCode: Int?
    public var lastAgentExitSignal: String?
    public var lastAgentExitAt: String?
    public var lastAgentDisconnectReason: String?
    public var historyEntries: Int
    /// The session's own MCP servers (set via `newSession` / `setSessionMcpServers`
    /// or `--mcp-config`), replayed on every reconnect; `nil` = the session uses the
    /// cwd's config-file servers.
    public var mcpServers: [McpServerConfig]?

    public init(
        id: String, sessionId: String, agentSessionId: String?, agentCommand: String,
        cwd: String, name: String?, createdAt: String, lastUsedAt: String,
        lastPromptAt: String?, closed: Bool, closedAt: String?, pid: Int?,
        agentStartedAt: String?, lastAgentExitCode: Int?, lastAgentExitSignal: String?,
        lastAgentExitAt: String?, lastAgentDisconnectReason: String?, historyEntries: Int,
        mcpServers: [McpServerConfig]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentSessionId = agentSessionId
        self.agentCommand = agentCommand
        self.cwd = cwd
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastPromptAt = lastPromptAt
        self.closed = closed
        self.closedAt = closedAt
        self.pid = pid
        self.agentStartedAt = agentStartedAt
        self.lastAgentExitCode = lastAgentExitCode
        self.lastAgentExitSignal = lastAgentExitSignal
        self.lastAgentExitAt = lastAgentExitAt
        self.lastAgentDisconnectReason = lastAgentDisconnectReason
        self.historyEntries = historyEntries
        self.mcpServers = mcpServers
    }
}

/// The daemon's `pruneSessions` result — mirrors the CLI's `sessions prune`.
public struct PruneResult: Codable, Sendable {
    public var count: Int
    public var bytesFreed: Int
    public var dryRun: Bool
    public var pruned: [String]

    public init(count: Int, bytesFreed: Int, dryRun: Bool, pruned: [String]) {
        self.count = count
        self.bytesFreed = bytesFreed
        self.dryRun = dryRun
        self.pruned = pruned
    }
}

/// One row of the daemon's `sessionHistory` result (oldest-first) — a turn's role,
/// timestamp, and a short text preview.
public struct HistoryEntry: Codable, Sendable {
    public var role: String
    public var timestamp: String
    public var textPreview: String

    public init(role: String, timestamp: String, textPreview: String) {
        self.role = role
        self.timestamp = timestamp
        self.textPreview = textPreview
    }
}
