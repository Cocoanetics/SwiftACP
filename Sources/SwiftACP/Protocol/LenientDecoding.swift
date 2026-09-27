import Foundation

// Lists read as the ACP SDK's schema reads them (`schema-deserialize.ts`), where it is
// lenient: a list keeps the entries that fit, where decoding would otherwise fail the
// whole update. A single member is read so by `lenient(_:forKey:)` (`SessionReplyCoding.swift`).
extension KeyedDecodingContainer {
    /// The SDK's `vecSkipError` under `defaultOnError`: the entries that don't decode are
    /// skipped, and a member that is no list reads as `fallback`. One left out is `nil`.
    func lenientList<T: Decodable>(_ type: T.Type, forKey key: Key, fallback: [T]?) -> [T]? {
        guard contains(key) else { return nil }
        guard let entries = try? decode([Skippable<T>].self, forKey: key) else { return fallback }
        return entries.compactMap(\.value)
    }

    /// The SDK's `requiredDefaultOnError` over `vecSkipError`: as ``lenientList(_:forKey:fallback:)``
    /// with an empty fallback, but the whole value fails when the list is left out.
    func requiredLenientList<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key, DecodingError.Context(codingPath: codingPath, debugDescription: "Required value is missing"))
        }
        return lenientList(type, forKey: key, fallback: []) ?? []
    }
}

/// An entry of a list that may not decode: `nil` then, rather than failing the list.
private struct Skippable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
