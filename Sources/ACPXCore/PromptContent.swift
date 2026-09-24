import Foundation
import JSONFoundation
import SwiftACP

/// acpx's `src/prompt-content.ts`: what a structured prompt may hold, how a block it
/// does not take is named, and how a prompt's source becomes content blocks.
///
/// A source that starts with `[` and parses (as `JSON.parse` parses) as an array is a
/// structured prompt: an array of ACP content blocks, sent to the agent as written. acpx
/// checks each block for the fields its type needs and nothing more — any `image/*` or
/// `audio/*` type, a `blob` resource, a `resource_link` of any name — and refuses the
/// first block that falls short in its own words (`prompt[<i>] …`).
public enum PromptContent {
    /// acpx's `PromptInputValidationError`: a structured prompt with a block acpx does
    /// not take. Its CLI reports it as a usage error.
    public struct ValidationError: Error, Equatable, CustomStringConvertible, LocalizedError {
        public let message: String
        public var description: String { message }
        public var errorDescription: String? { message }

        public init(message: String) {
            self.message = message
        }
    }

    /// acpx's `parsePromptSource`: the source trimmed as JavaScript trims; a JSON array
    /// of content blocks is those blocks; one holding a block acpx does not take is
    /// refused (``ValidationError``); anything else — text that merely opens with a
    /// bracket included — is one text block, or nothing when it is blank.
    public static func parse(_ source: String) throws -> [WireJSON] {
        let trimmed = source.javaScriptTrimmed
        if let structured = try structured(trimmed) { return structured }
        return trimmed.isEmpty ? [] : [textBlock(trimmed)]
    }

    /// acpx's `mergePromptSourceWithText`: the source's blocks, then `text`, trimmed, as
    /// one more text block — or as the only one, when the source has none.
    public static func parse(_ source: String, appending text: String) throws -> [WireJSON] {
        let prompt = try parse(source)
        let appended = text.javaScriptTrimmed
        guard !appended.isEmpty else { return prompt }
        return prompt + [textBlock(appended)]
    }

    /// `content` — blocks a caller sent as written — as ACP content after `text`, each
    /// checked by acpx's rules first (``validationError(of:at:)``).
    ///
    /// - Parameter requestLimit: cap on the encoded request in bytes, as
    ///   ``PromptBlock/contentBlocks(text:blocks:requestLimit:)`` caps it; `nil` for none.
    public static func contentBlocks(text: String, content: [JSONValue], requestLimit: Int?) throws -> [ContentBlock] {
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        var requestBytes = text.utf8.count + PromptBlock.envelopeReserve
        for (index, value) in content.enumerated() {
            let data = try JSONEncoder().encode(value)
            if let block = WireJSON(parsing: data), let problem = validationError(of: block, at: index) {
                throw ValidationError(message: problem)
            }
            blocks.append(try JSONDecoder().decode(ContentBlock.self, from: data))
            requestBytes += data.count
            if let requestLimit, requestBytes > requestLimit {
                throw PromptBlockError.tooLarge(requestBytes: requestBytes, limit: requestLimit)
            }
        }
        guard !blocks.isEmpty else { throw PromptBlockError.emptyPrompt }
        return blocks
    }

    /// acpx's `textPrompt`.
    public static func textBlock(_ text: String) -> WireJSON {
        .object([
            WireJSON.Member(key: Array("type".utf16), value: .text("text")),
            WireJSON.Member(key: Array("text".utf16), value: .text(text))
        ])
    }

    /// acpx's `parseStructuredPrompt`.
    private static func structured(_ source: String) throws -> [WireJSON]? {
        guard source.hasPrefix("["), case .array(let blocks)? = try? WireJSON.parse(source) else { return nil }
        guard blocks.allSatisfy(isContentBlock) else {
            throw ValidationError(message: blocks.indices.lazy.compactMap { validationError(of: blocks[$0], at: $0) }
                .first ?? "Structured prompt JSON must be an array of valid ACP content blocks")
        }
        return blocks
    }

    // MARK: - Blocks

    /// acpx's `getContentBlockValidationError`: why `block`, at `index`, is not a content
    /// block acpx sends — `nil` when it is.
    public static func validationError(of block: WireJSON, at index: Int) -> String? {
        guard case .object = block, case .string(let type)? = block["type"] else {
            return "prompt[\(index)] must be an ACP content block object"
        }
        switch String(decoding: type, as: UTF16.self) {
        case "text":
            guard case .string? = block["text"] else {
                return "prompt[\(index)] text block must include a string text field"
            }
            return nil
        case "image": return mediaError(block, index: index, kind: "image")
        case "audio": return mediaError(block, index: index, kind: "audio")
        case "resource_link":
            if !isNonEmptyString(block["uri"]) {
                return "prompt[\(index)] resource_link block must include a non-empty uri"
            }
            if !isAbsentOrNull(block["title"]), block["title"]?.stringValue == nil {
                return "prompt[\(index)] resource_link block title must be a string or null when present"
            }
            guard case .string? = block["name"] else {
                return "prompt[\(index)] resource_link block must include a string name"
            }
            return nil
        case "resource":
            guard let resource = block["resource"], case .object = resource else {
                return "prompt[\(index)] resource block must include a resource object"
            }
            guard isResourcePayload(resource) else {
                return "prompt[\(index)] resource block resource must include a non-empty uri "
                    + "and a string text or blob field"
            }
            return nil
        default:
            return "prompt[\(index)] has unsupported content block type \(WireJSON.string(type).stringified)"
        }
    }

    /// acpx's `validateImageContentBlock` / `validateAudioContentBlock`.
    private static func mediaError(_ block: WireJSON, index: Int, kind: String) -> String? {
        guard isNonEmptyString(block["mimeType"]), let mimeType = block["mimeType"]?.stringValue else {
            return "prompt[\(index)] \(kind) block must include a non-empty mimeType"
        }
        guard isMediaType(mimeType, of: kind) else {
            return "prompt[\(index)] \(kind) block mimeType must start with \(kind)/"
        }
        guard case .string(let data)? = block["data"], !data.isEmpty else {
            return "prompt[\(index)] \(kind) block must include non-empty base64 data"
        }
        return isBase64(data) ? nil : "prompt[\(index)] \(kind) block data must be valid base64"
    }

    /// acpx's `isContentBlock`: whether any block validator takes `value`. It agrees
    /// with ``validationError(of:at:)``, which says why none does.
    static func isContentBlock(_ value: WireJSON) -> Bool {
        validationError(of: value, at: 0) == nil
    }

    /// acpx's `isResourcePayload`.
    private static func isResourcePayload(_ resource: WireJSON) -> Bool {
        guard isNonEmptyString(resource["uri"]) else { return false }
        if case .string? = resource["text"] { return true }
        if case .string? = resource["blob"] { return true }
        return false
    }

    /// acpx's `isNonEmptyString`: a string with something left once trimmed.
    private static func isNonEmptyString(_ value: WireJSON?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return !text.javaScriptTrimmed.isEmpty
    }

    /// `value == null`: absent, or JSON null.
    private static func isAbsentOrNull(_ value: WireJSON?) -> Bool {
        guard let value else { return true }
        if case .null = value { return true }
        return false
    }

    /// acpx's `isImageMimeType` / `isAudioMimeType`: `/^<kind>\/[A-Za-z0-9.+-]+$/i`.
    private static func isMediaType(_ mimeType: String, of kind: String) -> Bool {
        let units = Array(mimeType.utf16)
        let prefix = Array("\(kind)/".utf16)
        guard units.count > prefix.count,
            zip(units, prefix).allSatisfy({ asciiLowercased($0) == $1 })
        else { return false }
        return units.dropFirst(prefix.count).allSatisfy { unit in
            isASCIIAlphanumeric(unit) || unit == 0x2E || unit == 0x2B || unit == 0x2D  // . + -
        }
    }

    /// acpx's `isBase64Data`: whole groups of four from the base64 alphabet, padding
    /// only at the end.
    private static func isBase64(_ units: [UInt16]) -> Bool {
        guard !units.isEmpty, units.count % 4 == 0 else { return false }
        let padding = units.reversed().prefix { $0 == 0x3D }.count  // =
        guard padding <= 2 else { return false }
        return units.dropLast(padding).allSatisfy { unit in
            isASCIIAlphanumeric(unit) || unit == 0x2B || unit == 0x2F  // + /
        }
    }

    private static func isASCIIAlphanumeric(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func asciiLowercased(_ unit: UInt16) -> UInt16 {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }
}
