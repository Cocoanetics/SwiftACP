import Foundation
import JSONFoundation

// How the replies that open a session and set one of its options are read: as acpx takes
// them. Its ACP SDK (1.5.0) checks what an agent asks and announces, but no reply, so acpx
// reads a reply's members off whatever the agent sent. A malformed member fails nothing:
//
// - `configOptions` is kept as sent (``NewSessionResponse/rawConfigOptions``), for acpx
//   records it whatever it holds. Only a list of them is read as options.
// - `models`, the legacy model list, is kept as sent too: acpx tells a `null` one from
//   none (`hasResponseField`).
// - `modes`, which acpx never reads, is read as the ACP schema reads it
//   (`zSessionModeState`), and is left out when it doesn't fit.
//
// Split from `Session.swift` to keep each file inside the 500-line limit.

extension KeyedDecodingContainer {
    /// The member `key` as sent, whatever it holds: `nil` when there is none, and
    /// ``JSONValue/null`` when it is `null`.
    func raw(forKey key: Key) throws -> JSONValue? {
        // Not `contains(key) ? … : nil`: that `nil` would be `JSONValue.null`, a member
        // read as null rather than as none.
        guard contains(key) else { return .none }
        return try decode(JSONValue.self, forKey: key)
    }

    /// The member `key` when it fits `type`; `nil` when there is none, it is `null`, or it
    /// doesn't fit — the ACP schema's `defaultOnError(schema.nullish(), () => undefined)`.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        // `try?` flattens `decodeIfPresent`'s optional into its own.
        try? decodeIfPresent(type, forKey: key)
    }
}

extension NewSessionResponse {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(SessionId.self, forKey: .sessionId)
        modes = container.lenient(SessionModeState.self, forKey: .modes)
        rawConfigOptions = try container.raw(forKey: .configOptions)
        models = try container.raw(forKey: .models)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(modes, forKey: .modes)
        try container.encodeIfPresent(rawConfigOptions, forKey: .configOptions)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension LoadSessionResponse {
    /// A `null` reply, or a list, reports nothing: acpx asks it for its members (`in`)
    /// and finds none. Any other reply that is no object fails, as acpx's `in` throws.
    public init(from decoder: Decoder) throws {
        self.init()
        if try Self.reportsNothing(decoder) { return }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modes = container.lenient(SessionModeState.self, forKey: .modes)
        rawConfigOptions = try container.raw(forKey: .configOptions)
        models = try container.raw(forKey: .models)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modes, forKey: .modes)
        try container.encodeIfPresent(rawConfigOptions, forKey: .configOptions)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(meta, forKey: .meta)
    }

    private static func reportsNothing(_ decoder: Decoder) throws -> Bool {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return true }
        return (try? value.decode([JSONValue].self)) != nil
    }
}

extension SetSessionConfigOptionResponse {
    /// A reply that is no object only acknowledges: acpx reads its `configOptions` as
    /// undefined (a `null` reply included, which acpx reads that way for a model, while
    /// for any other option a `TypeError` fails it).
    public init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        rawConfigOptions = try container.raw(forKey: .configOptions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rawConfigOptions, forKey: .configOptions)
    }
}

extension SessionModeState {
    /// `zSessionModeState`: the current mode must be there, and a list of modes, but a
    /// list that isn't one reads as empty (`requiredDefaultOnError`), and a mode that
    /// doesn't fit is left out of it (`vecSkipError`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentModeId = try container.decode(String.self, forKey: .currentModeId)
        guard container.contains(.availableModes) else {
            throw DecodingError.keyNotFound(CodingKeys.availableModes, DecodingError.Context(
                codingPath: container.codingPath, debugDescription: "Required value is missing"))
        }
        let modes = try? container.decode([FittingMode].self, forKey: .availableModes)
        availableModes = modes?.compactMap(\.mode) ?? []
    }

    /// A mode in the list, `nil` when it doesn't fit.
    private struct FittingMode: Decodable {
        let mode: SessionMode?

        init(from decoder: Decoder) throws {
            mode = try? SessionMode(from: decoder)
        }
    }
}

extension SessionMode {
    /// `zSessionMode`: an id and a name, and a description only when it is a string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = container.lenient(String.self, forKey: .description)
    }
}
