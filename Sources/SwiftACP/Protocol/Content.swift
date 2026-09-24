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
    /// Whatever else the block carried — see ``ContentMembers``.
    public var extraMembers: [String: JSONValue] = [:]

    public init(text: String, annotations: JSONValue? = nil, meta: JSONValue? = nil) {
        self.text = text
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        var members = try ContentMembers.Reader(decoder)
        type = try members.required(String.self, "type")
        text = try members.required(String.self, "text")
        annotations = members.optional(JSONValue.self, "annotations")
        meta = members.optional(JSONValue.self, "_meta")
        extraMembers = try members.rest()
    }

    public func encode(to encoder: Encoder) throws {
        var members = ContentMembers.Writer(encoder)
        try members.write(type, "type")
        try members.write(text, "text")
        try members.write(annotations, "annotations")
        try members.write(meta, "_meta")
        try members.write(extraMembers)
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
    /// Whatever else the block carried — see ``ContentMembers``.
    public var extraMembers: [String: JSONValue] = [:]

    public init(
        data: String, mimeType: String, uri: String? = nil, annotations: JSONValue? = nil, meta: JSONValue? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        var members = try ContentMembers.Reader(decoder)
        type = try members.required(String.self, "type")
        data = try members.required(String.self, "data")
        mimeType = try members.required(String.self, "mimeType")
        uri = members.optional(String.self, "uri")
        annotations = members.optional(JSONValue.self, "annotations")
        meta = members.optional(JSONValue.self, "_meta")
        extraMembers = try members.rest()
    }

    public func encode(to encoder: Encoder) throws {
        var members = ContentMembers.Writer(encoder)
        try members.write(type, "type")
        try members.write(data, "data")
        try members.write(mimeType, "mimeType")
        try members.write(uri, "uri")
        try members.write(annotations, "annotations")
        try members.write(meta, "_meta")
        try members.write(extraMembers)
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
    /// Whatever else the block carried — see ``ContentMembers``.
    public var extraMembers: [String: JSONValue] = [:]

    public init(data: String, mimeType: String, annotations: JSONValue? = nil, meta: JSONValue? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        var members = try ContentMembers.Reader(decoder)
        type = try members.required(String.self, "type")
        data = try members.required(String.self, "data")
        mimeType = try members.required(String.self, "mimeType")
        annotations = members.optional(JSONValue.self, "annotations")
        meta = members.optional(JSONValue.self, "_meta")
        extraMembers = try members.rest()
    }

    public func encode(to encoder: Encoder) throws {
        var members = ContentMembers.Writer(encoder)
        try members.write(type, "type")
        try members.write(data, "data")
        try members.write(mimeType, "mimeType")
        try members.write(annotations, "annotations")
        try members.write(meta, "_meta")
        try members.write(extraMembers)
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
    /// Whatever else the block carried — see ``ContentMembers``.
    public var extraMembers: [String: JSONValue] = [:]

    public init(resource: ResourceContents, annotations: JSONValue? = nil, meta: JSONValue? = nil) {
        self.resource = resource
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        var members = try ContentMembers.Reader(decoder)
        type = try members.required(String.self, "type")
        resource = try members.required(ResourceContents.self, "resource")
        annotations = members.optional(JSONValue.self, "annotations")
        meta = members.optional(JSONValue.self, "_meta")
        extraMembers = try members.rest()
    }

    public func encode(to encoder: Encoder) throws {
        var members = ContentMembers.Writer(encoder)
        try members.write(type, "type")
        try members.write(resource, "resource")
        try members.write(annotations, "annotations")
        try members.write(meta, "_meta")
        try members.write(extraMembers)
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
    /// Whatever else the resource carried — see ``ContentMembers``.
    public var extraMembers: [String: JSONValue] = [:]

    public init(
        uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil, meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        var members = try ContentMembers.Reader(decoder)
        uri = try members.required(String.self, "uri")
        mimeType = members.optional(String.self, "mimeType")
        text = members.optional(String.self, "text")
        blob = members.optional(String.self, "blob")
        meta = members.optional(JSONValue.self, "_meta")
        extraMembers = try members.rest()
    }

    public func encode(to encoder: Encoder) throws {
        var members = ContentMembers.Writer(encoder)
        try members.write(uri, "uri")
        try members.write(mimeType, "mimeType")
        try members.write(text, "text")
        try members.write(blob, "blob")
        try members.write(meta, "_meta")
        try members.write(extraMembers)
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
    /// Whatever else the block carried — a `"title": null` among it — see
    /// ``ContentMembers``.
    public var extraMembers: [String: JSONValue] = [:]

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

    public init(from decoder: Decoder) throws {
        var members = try ContentMembers.Reader(decoder)
        type = try members.required(String.self, "type")
        uri = try members.required(String.self, "uri")
        name = try members.required(String.self, "name")
        mimeType = members.optional(String.self, "mimeType")
        title = members.optional(String.self, "title")
        description = members.optional(String.self, "description")
        size = members.optional(Int.self, "size")
        annotations = members.optional(JSONValue.self, "annotations")
        meta = members.optional(JSONValue.self, "_meta")
        extraMembers = try members.rest()
    }

    public func encode(to encoder: Encoder) throws {
        var members = ContentMembers.Writer(encoder)
        try members.write(type, "type")
        try members.write(uri, "uri")
        try members.write(name, "name")
        try members.write(mimeType, "mimeType")
        try members.write(title, "title")
        try members.write(description, "description")
        try members.write(size, "size")
        try members.write(annotations, "annotations")
        try members.write(meta, "_meta")
        try members.write(extraMembers)
    }
}

/// How a content block's members are read and written so that it goes on as it came:
/// acpx passes a prompt's blocks to the agent as written. A block's type holds the
/// members ACP defines; everything else it carried — members it does not know, and
/// known ones sent as `null` or with a type it does not expect — is kept as its
/// `extraMembers` and written back as it was. Only the members a block cannot do
/// without are read strictly.
public enum ContentMembers {
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct Reader {
        private let container: KeyedDecodingContainer<Key>
        private var left: Set<String>

        init(_ decoder: Decoder) throws {
            container = try decoder.container(keyedBy: Key.self)
            left = Set(container.allKeys.map(\.stringValue))
        }

        /// A member the block cannot do without: absent or of another type, it fails.
        mutating func required<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            let value = try container.decode(T.self, forKey: Key(name))
            left.remove(name)
            return value
        }

        /// A member the block may have: `nil` when it is absent, `null` or of another
        /// type, which then stays among the rest.
        mutating func optional<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            let key = Key(name)
            guard container.contains(key), (try? container.decodeNil(forKey: key)) == false,
                  let value = try? container.decode(T.self, forKey: key)
            else { return nil }
            left.remove(name)
            return value
        }

        /// The members nothing has read, as they came.
        func rest() throws -> [String: JSONValue] {
            try left.reduce(into: [:]) { rest, name in
                rest[name] = try container.decode(JSONValue.self, forKey: Key(name))
            }
        }
    }

    struct Writer {
        private var container: KeyedEncodingContainer<Key>
        private var written: Set<String> = []

        init(_ encoder: Encoder) {
            container = encoder.container(keyedBy: Key.self)
        }

        mutating func write<T: Encodable>(_ value: T?, _ name: String) throws {
            guard let value else { return }
            try container.encode(value, forKey: Key(name))
            written.insert(name)
        }

        /// The rest, but for a member the block now holds itself.
        mutating func write(_ extra: [String: JSONValue]) throws {
            for (name, value) in extra where !written.contains(name) {
                try container.encode(value, forKey: Key(name))
            }
        }
    }
}
