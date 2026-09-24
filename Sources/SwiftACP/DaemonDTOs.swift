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

/// One content block of a `runPrompt` turn — ACP's own prompt shape, flattened.
///
/// A discriminated union in a struct, because an MCP tool parameter needs a JSON
/// schema (`@Schema`), which only structs get: `type` picks the block, and the field
/// set that block uses is documented per field. ``contentBlocks(text:blocks:requestLimit:)``
/// validates the combination and maps it onto the wire enum ``ContentBlock``.
///
/// Which blocks are worth sending, verified against both shipped adapters:
///
/// - `text` and `image` are the everyday pair, and both adapters map an image onto
///   their model's native image input.
/// - `resource_link` is how you hand over a file: both adapters render it as a link
///   and let the agent open the file with its own tools. This is the path for a PDF
///   or anything else that is not an image.
/// - `resource` carries text inline (both wrap it in `<context ref="…">`). It cannot
///   carry a binary here: `claude-agent-acp` drops an embedded blob outright and
///   `codex-acp` inlines its base64 into the prompt text, where it costs tokens and
///   the model answers from surrounding context rather than erroring — so a binary
///   `resource` is refused, pointing at `resource_link` instead.
/// - `audio` is accepted and gated, but no adapter advertises `promptCapabilities.audio`
///   today, so in practice it is always refused.
@Schema
public struct PromptBlock: Codable, Hashable, Sendable {
    /// Which block this is: `text`, `image`, `audio`, `resource_link` or `resource`.
    public var type: String
    /// `text`: the message. `resource`: the resource's contents, inline.
    public var text: String?
    /// `image` / `audio`: the payload, base64-encoded — bare, with no `data:` prefix.
    public var data: String?
    /// `image` / `audio`: the payload's MIME type. `resource` / `resource_link`: the
    /// referenced resource's type, when known.
    public var mimeType: String?
    /// `resource_link` / `resource`: what is being referenced, as a URI.
    public var uri: String?
    /// `resource_link`: the name to show. Defaults to the URI's last path component.
    public var name: String?
    /// `resource_link`: a longer label, when the name is not the whole story.
    public var title: String?

    public init(
        type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil,
        uri: String? = nil, name: String? = nil, title: String? = nil
    ) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.name = name
        self.title = title
    }

    // MARK: Convenience

    public static func text(_ text: String) -> PromptBlock {
        PromptBlock(type: "text", text: text)
    }

    public static func image(mimeType: String, data: String) -> PromptBlock {
        PromptBlock(type: "image", data: data, mimeType: mimeType)
    }

    /// A file handed to the agent by reference — the working path for a PDF or any
    /// other non-image, since the agent opens it with its own tools.
    public static func resourceLink(
        uri: String, name: String? = nil, mimeType: String? = nil
    ) -> PromptBlock {
        PromptBlock(type: "resource_link", mimeType: mimeType, uri: uri, name: name)
    }
}

extension PromptBlock {
    /// The image types the agents' models actually accept. Stricter than ACP (which
    /// gates only on `promptCapabilities.image`) and stricter than npm acpx (which
    /// checks the `image/` prefix and nothing more), because neither adapter
    /// validates: an `image/bmp` sails through both and fails at the model instead.
    public static let supportedImageMimeTypes =
        ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Ceiling on a whole `runPrompt` request as it travels.
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
    /// escaping the text picks up on the way into JSON. Base64 needs none: its
    /// alphabet survives JSON quoting byte for byte.
    static let envelopeReserve = 8 * 1024

    /// Validate `blocks` and map them, after `text`, onto ACP content blocks — the
    /// order npm acpx's `toPromptInput` uses.
    ///
    /// Empty text contributes no block, so a turn can be carried by its blocks alone;
    /// an empty prompt overall is rejected, since every agent errors on one anyway.
    ///
    /// - Parameter requestLimit: cap on the encoded request in bytes, or `nil` for no
    ///   cap. The daemon passes ``maxRequestBytes`` because its transport has a
    ///   ceiling; a caller talking to an agent directly has nothing in the way.
    public static func contentBlocks(
        text: String, blocks: [PromptBlock]?, requestLimit: Int?
    ) throws -> [ContentBlock] {
        var content: [ContentBlock] = []
        if !text.isEmpty { content.append(.text(text)) }

        // Size the request the way the transport will: payloads as encoded, plus the
        // text they travel with, plus slack for the envelope around them.
        var requestBytes = text.utf8.count + envelopeReserve
        for (index, block) in (blocks ?? []).enumerated() {
            content.append(try block.contentBlock(index: index))
            requestBytes += block.encodedSize
            if let requestLimit, requestBytes > requestLimit {
                throw PromptBlockError.tooLarge(requestBytes: requestBytes, limit: requestLimit)
            }
        }

        guard !content.isEmpty else { throw PromptBlockError.emptyPrompt }
        return content
    }

    /// Roughly what this block adds to the request on the wire.
    private var encodedSize: Int {
        [text, data, mimeType, uri, name, title].compactMap { $0?.utf8.count }.reduce(0, +)
    }

    /// This block as its ACP wire form, or a per-index error saying what is wrong.
    func contentBlock(index: Int) throws -> ContentBlock {
        switch type {
        case "text":
            return .text(try required(text, index: index, field: "text"))

        case "image":
            let mimeType = try required(self.mimeType, index: index, field: "mimeType")
            guard Self.supportedImageMimeTypes.contains(mimeType.lowercased()) else {
                throw PromptBlockError.unsupportedImageMimeType(index: index, mimeType: mimeType)
            }
            return .image(
                ImageContent(data: try base64(index: index), mimeType: mimeType))

        case "audio":
            let mimeType = try required(self.mimeType, index: index, field: "mimeType")
            guard mimeType.lowercased().hasPrefix("audio/") else {
                throw PromptBlockError.unsupportedAudioMimeType(index: index, mimeType: mimeType)
            }
            return .audio(
                AudioContent(data: try base64(index: index), mimeType: mimeType))

        case "resource_link":
            let uri = try required(self.uri, index: index, field: "uri")
            return .resourceLink(
                ResourceLink(
                    uri: uri, name: name ?? Self.fileName(of: uri), mimeType: mimeType,
                    title: title))

        case "resource":
            let uri = try required(self.uri, index: index, field: "uri")
            // No `blob` field on purpose — see the type's docs. A caller reaching for
            // one wants `resource_link` (any file) or `image` (an image).
            guard let text else { throw PromptBlockError.binaryResource(index: index) }
            return .resource(
                EmbeddedResource(
                    resource: ResourceContents(uri: uri, mimeType: mimeType, text: text)))

        default:
            throw PromptBlockError.unsupportedBlockType(index: index, type: type)
        }
    }

    private func required(_ value: String?, index: Int, field: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw PromptBlockError.missingField(index: index, type: type, field: field)
        }
        return value
    }

    /// Reject padding-less / whitespace-wrapped payloads too: the adapters pass base64
    /// straight through, so anything we let past fails at the model.
    private func base64(index: Int) throws -> String {
        let data = try required(self.data, index: index, field: "data")
        guard let decoded = Data(base64Encoded: data), !decoded.isEmpty else {
            throw PromptBlockError.invalidBase64(index: index)
        }
        return data
    }

    private static func fileName(of uri: String) -> String {
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
        return path.split(separator: "/").last.map(String.init) ?? uri
    }
}

/// Why a turn's prompt blocks were refused before reaching the agent.
public enum PromptBlockError: LocalizedError, Equatable {
    case unsupportedBlockType(index: Int, type: String)
    case missingField(index: Int, type: String, field: String)
    case unsupportedImageMimeType(index: Int, mimeType: String)
    case unsupportedAudioMimeType(index: Int, mimeType: String)
    case invalidBase64(index: Int)
    case binaryResource(index: Int)
    case tooLarge(requestBytes: Int, limit: Int)
    case emptyPrompt
    /// The agent's `initialize` did not advertise the capability this block needs.
    case capabilityUnsupported(index: Int, capability: String, agent: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBlockType(let index, let type):
            return """
                prompt[\(index)]: unknown block type "\(type)" — expected text, image, \
                audio, resource_link or resource
                """
        case .missingField(let index, let type, let field):
            return "prompt[\(index)]: a \(type) block needs a non-empty \(field)"
        case .unsupportedImageMimeType(let index, let mimeType):
            return """
                prompt[\(index)]: unsupported image mimeType "\(mimeType)" — \
                expected one of \(PromptBlock.supportedImageMimeTypes.joined(separator: ", ")). \
                To share a PDF or other file, send a resource_link and let the agent open it.
                """
        case .unsupportedAudioMimeType(let index, let mimeType):
            return "prompt[\(index)]: an audio block needs an audio/* mimeType, not \"\(mimeType)\""
        case .invalidBase64(let index):
            return "prompt[\(index)]: data must be non-empty, unwrapped base64"
        case .binaryResource(let index):
            return """
                prompt[\(index)]: an embedded resource must carry text. Agents cannot read \
                an inlined binary — send a resource_link so the agent opens the file itself, \
                or an image block for an image.
                """
        case .tooLarge(let requestBytes, let limit):
            return """
                prompt exceeds the per-turn limit: \(requestBytes) bytes encoded, limit \(limit)
                """
        case .emptyPrompt:
            return "prompt must have text, blocks, or both"
        case .capabilityUnsupported(let index, let capability, let agent):
            return """
                prompt[\(index)]: agent "\(agent)" does not advertise \
                promptCapabilities.\(capability), so it cannot accept this block
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
    /// How the turn's permissions were settled, which decides the CLI's exit code
    /// (`PERMISSION_DENIED`, 5). `nil` from a daemon that predates it.
    public var permissions: PermissionStats?

    public init(stopReason: String, permissions: PermissionStats? = nil) {
        self.stopReason = stopReason
        self.permissions = permissions
    }
}

/// A request the agent made of the client during a daemon turn — `fs/write_text_file`,
/// `session/request_permission` — streamed as a log notification when it arrives,
/// and again with ``failure`` if the client refused it. acpx's formatter prints every
/// request and error it sees on the wire, so the CLI renders these as
/// `[client] <method> (running)` and `[error] RUNTIME: <failure>`, in order with the
/// turn's updates.
public struct InboundRequestEvent: Codable, Sendable {
    /// The request's method. Named apart from ``ClientOperation/method`` so the two
    /// cannot be mistaken for each other on the wire.
    public var inboundMethod: String
    /// Why the client refused it — the error's `data.details` when present, else its
    /// message — or `nil` when this reports the request arriving.
    public var failure: String?

    public init(inboundMethod: String, failure: String? = nil) {
        self.inboundMethod = inboundMethod
        self.failure = failure
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
