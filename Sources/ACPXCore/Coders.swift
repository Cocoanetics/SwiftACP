import Foundation
import JSONFoundation

/// JSON coders for acpx's on-disk files. Models use camelCase property names; the
/// coders translate to/from the on-disk casing:
///
/// - **Session records** (`sessions/<id>.json`) are snake_case. `recordDiskEncoder`
///   converts camelCase → snake_case but leaves PascalCase conversation tags
///   (`{"ToolUse": …}`) untouched; `recordDiskDecoder` does the inverse. Foundation
///   key strategies skip dictionary keys, so opaque `JSONValue` blobs
///   (`agent_capabilities`, tool `input`/`output`, `config_options`) pass through
///   verbatim.
/// - **Index** (`index.json`) and **config** are already camelCase, so they use the
///   plain coders with no key strategy.
///
/// The CLI's `--format json` output encodes the same camelCase models with a plain
/// encoder, yielding a uniform camelCase view.

extension JSONEncoder.KeyEncodingStrategy {
    /// camelCase → snake_case, except keys that begin with an uppercase letter
    /// (the Zed conversation discriminators `User`/`Agent`/`ToolUse`/…), which are
    /// passed through unchanged so the tagged unions still round-trip.
    static var acpxRecordKeys: JSONEncoder.KeyEncodingStrategy {
        .custom { path in
            let key = path.last!
            guard key.intValue == nil else { return key }
            let name = key.stringValue
            if let first = name.first, first.isUppercase { return key }
            var out = ""
            for character in name {
                if character.isUppercase {
                    out.append("_")
                    out.append(contentsOf: character.lowercased())
                } else {
                    out.append(character)
                }
            }
            return AnyCodingKey(out)
        }
    }
}

/// Snake_case encoder for on-disk session records (pretty, deterministic).
let recordDiskEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .acpxRecordKeys
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// Decoder for on-disk session records (snake_case → camelCase properties).
let recordDiskDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

/// Plain encoder for the camelCase index/config files (pretty, deterministic).
let plainDiskEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// Plain decoder for the camelCase index/config files.
let plainDecoder = JSONDecoder()
