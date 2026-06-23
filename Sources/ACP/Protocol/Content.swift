import Foundation
import JSONValue

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

public struct TextContent: Codable, Hashable, Sendable {
    public var type = "text"
    public var text: String
    public var annotations: JSONValue?

    public init(text: String, annotations: JSONValue? = nil) {
        self.text = text
        self.annotations = annotations
    }
}

public struct ImageContent: Codable, Hashable, Sendable {
    public var type = "image"
    /// Base64-encoded image data.
    public var data: String
    public var mimeType: String
    public var uri: String?
    public var annotations: JSONValue?

    public init(data: String, mimeType: String, uri: String? = nil, annotations: JSONValue? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
    }
}

public struct AudioContent: Codable, Hashable, Sendable {
    public var type = "audio"
    /// Base64-encoded audio data.
    public var data: String
    public var mimeType: String
    public var annotations: JSONValue?

    public init(data: String, mimeType: String, annotations: JSONValue? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

public struct EmbeddedResource: Codable, Hashable, Sendable {
    public var type = "resource"
    public var resource: ResourceContents
    public var annotations: JSONValue?

    public init(resource: ResourceContents, annotations: JSONValue? = nil) {
        self.resource = resource
        self.annotations = annotations
    }
}

/// The body of an embedded resource — either text or base64 `blob`.
public struct ResourceContents: Codable, Hashable, Sendable {
    public var uri: String
    public var mimeType: String?
    public var text: String?
    public var blob: String?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}

public struct ResourceLink: Codable, Hashable, Sendable {
    public var type = "resource_link"
    public var uri: String
    public var name: String
    public var mimeType: String?
    public var title: String?
    public var description: String?
    public var size: Int?
    public var annotations: JSONValue?

    public init(
        uri: String, name: String, mimeType: String? = nil, title: String? = nil,
        description: String? = nil, size: Int? = nil, annotations: JSONValue? = nil
    ) {
        self.uri = uri
        self.name = name
        self.mimeType = mimeType
        self.title = title
        self.description = description
        self.size = size
        self.annotations = annotations
    }
}
