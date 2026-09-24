import Foundation
import JSONFoundation

/// A piece of content exchanged between client and agent.
///
/// Content blocks follow the same shape as MCP content, so prompts, agent
/// messages, tool-call payloads and resources all share one representation.
/// See https://agentclientprotocol.com/protocol/v1/content
public enum ContentBlock: Codable, Hashable, Sendable {
    case text(TextContent)
    case image(ImageContent)
    case audio(AudioContent)
    case resource(EmbeddedResource)
    case resourceLink(ResourceLink)

    // MARK: Convenience

    /// A plain text block — by far the most common content sent in a prompt.
    public static func text(_ text: String) -> ContentBlock {
        .text(TextContent(text: text))
    }

    /// The text carried by this block, if it is (or wraps) text.
    public var text: String? {
        switch self {
        case .text(let value): return value.text
        case .resource(let value): return value.resource.text
        default: return nil
        }
    }

    /// Which `promptCapabilities` flag the agent must advertise to accept this block
    /// in a prompt — `nil` for `text` and `resource_link`, which ACP never gates.
    ///
    /// Mirrors npm acpx's `promptCapabilityRequirement`, which its client checks
    /// before dispatch rather than letting the agent ignore a block it never claimed.
    public var requiredPromptCapability: PromptCapabilityRequirement? {
        switch self {
        case .text, .resourceLink: return nil
        case .image: return .image
        case .audio: return .audio
        case .resource: return .embeddedContext
        }
    }

    private enum DiscriminatorKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try TextContent(from: decoder))
        case "image": self = .image(try ImageContent(from: decoder))
        case "audio": self = .audio(try AudioContent(from: decoder))
        case "resource": self = .resource(try EmbeddedResource(from: decoder))
        case "resource_link": self = .resourceLink(try ResourceLink(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown content block type \"\(type)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value): try value.encode(to: encoder)
        case .image(let value): try value.encode(to: encoder)
        case .audio(let value): try value.encode(to: encoder)
        case .resource(let value): try value.encode(to: encoder)
        case .resourceLink(let value): try value.encode(to: encoder)
        }
    }
}

/// A `promptCapabilities` flag that gates one kind of prompt content block.
public enum PromptCapabilityRequirement: String, Sendable {
    case image
    case audio
    case embeddedContext

    /// Whether `capabilities` advertised this. An absent capabilities object — or an
    /// unset flag — means "not advertised", which ACP treats as off.
    public func isAdvertised(by capabilities: PromptCapabilities?) -> Bool {
        switch self {
        case .image: return capabilities?.image == true
        case .audio: return capabilities?.audio == true
        case .embeddedContext: return capabilities?.embeddedContext == true
        }
    }
}

/// Plain text, with optional MCP-style annotations.
public struct TextContent: Codable, Hashable, Sendable {
    public var type = "text"
    public var text: String
    public var annotations: JSONValue?
    /// `_meta`, passed on as given.
    public var meta: JSONValue?

    public init(text: String, annotations: JSONValue? = nil, meta: JSONValue? = nil) {
        self.text = text
        self.annotations = annotations
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case type, text, annotations
        case meta = "_meta"
    }
}

/// An image carried inline as base64 data with its MIME type.
public struct ImageContent: Codable, Hashable, Sendable {
    public var type = "image"
    /// Base64-encoded image data.
    public var data: String
    public var mimeType: String
    public var uri: String?
    public var annotations: JSONValue?
    /// `_meta`, passed on as given.
    public var meta: JSONValue?

    public init(
        data: String, mimeType: String, uri: String? = nil, annotations: JSONValue? = nil, meta: JSONValue? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case type, data, mimeType, uri, annotations
        case meta = "_meta"
    }
}

/// Audio carried inline as base64 data with its MIME type.
public struct AudioContent: Codable, Hashable, Sendable {
    public var type = "audio"
    /// Base64-encoded audio data.
    public var data: String
    public var mimeType: String
    public var annotations: JSONValue?
    /// `_meta`, passed on as given.
    public var meta: JSONValue?

    public init(data: String, mimeType: String, annotations: JSONValue? = nil, meta: JSONValue? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case type, data, mimeType, annotations
        case meta = "_meta"
    }
}

/// A resource included in full (e.g. attached file context) so the receiver
/// can use it without a follow-up read.
public struct EmbeddedResource: Codable, Hashable, Sendable {
    public var type = "resource"
    public var resource: ResourceContents
    public var annotations: JSONValue?
    /// `_meta`, passed on as given.
    public var meta: JSONValue?

    public init(resource: ResourceContents, annotations: JSONValue? = nil, meta: JSONValue? = nil) {
        self.resource = resource
        self.annotations = annotations
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case type, resource, annotations
        case meta = "_meta"
    }
}

/// The body of an embedded resource — either text or base64 `blob`.
public struct ResourceContents: Codable, Hashable, Sendable {
    public var uri: String
    public var mimeType: String?
    public var text: String?
    public var blob: String?
    /// `_meta`, passed on as given.
    public var meta: JSONValue?

    public init(
        uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil, meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case uri, mimeType, text, blob
        case meta = "_meta"
    }
}

/// A reference to a resource by URI, without embedding its contents.
public struct ResourceLink: Codable, Hashable, Sendable {
    public var type = "resource_link"
    public var uri: String
    public var name: String
    public var mimeType: String?
    public var title: String?
    public var description: String?
    public var size: Int?
    public var annotations: JSONValue?
    /// `_meta`, passed on as given.
    public var meta: JSONValue?
    /// Whether the block said `"title": null`, which goes on as said: acpx passes a
    /// prompt's blocks to the agent as written.
    private var titleIsNull = false

    public init(
        uri: String, name: String, mimeType: String? = nil, title: String? = nil,
        description: String? = nil, size: Int? = nil, annotations: JSONValue? = nil, meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.name = name
        self.mimeType = mimeType
        self.title = title
        self.description = description
        self.size = size
        self.annotations = annotations
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case type, uri, name, mimeType, title, description, size, annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        uri = try container.decode(String.self, forKey: .uri)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleIsNull = title == nil && container.contains(.title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        annotations = try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(uri, forKey: .uri)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        if let title {
            try container.encode(title, forKey: .title)
        } else if titleIsNull {
            try container.encodeNil(forKey: .title)
        }
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}
