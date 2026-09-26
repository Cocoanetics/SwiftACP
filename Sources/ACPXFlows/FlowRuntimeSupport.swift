import ACPXCore
import CryptoKit
import Foundation
import SwiftACP

/// acpx's `src/flows/runtime-support.ts` (v0.19.3): the identifiers, summaries and small
/// rules the runner shares.
enum FlowRuntimeSupport {
    /// acpx's `createRunId`: the start time without `:` and `.`, the flow's name as a slug,
    /// and eight characters of a random UUID.
    static func runId(flowName: String, now: String = nowISO(), uuid: UUID = UUID()) -> String {
        let stamp = now.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ".", with: "")
        let random = String(uuid.uuidString.lowercased().prefix(8))
        return "\(stamp)-\(slugifyAsciiIdPart(flowName))-\(random)"
    }

    /// acpx's `slugifyAsciiIdPart`: ASCII letters (lowercased) and digits kept, each run of
    /// anything else one `-`, none leading or trailing. It walks code points, and reads
    /// each by its first UTF-16 unit.
    static func slugifyAsciiIdPart(_ value: String) -> String {
        var slug = ""
        var lastWasSeparator = false
        for scalar in value.unicodeScalars {
            let code = scalar.utf16.first ?? 0
            if let kept = lowerAsciiAlphaNumeric(code) {
                slug.append(kept)
                lastWasSeparator = false
            } else if !slug.isEmpty, !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        if lastWasSeparator { slug.removeLast() }
        return slug
    }

    private static func lowerAsciiAlphaNumeric(_ code: UInt16) -> Character? {
        switch code {
        case 48...57, 97...122: return Character(Unicode.Scalar(code)!)
        case 65...90: return Character(Unicode.Scalar(code + 32)!)
        default: return nil
        }
    }

    /// acpx's `nextAttemptId`: the node's id and how many times it has run, `#` between.
    static func nextAttemptId(_ counts: inout [String: Int], nodeId: String) -> String {
        let next = (counts[nodeId] ?? 0) + 1
        counts[nodeId] = next
        return "\(nodeId)#\(next)"
    }

    /// acpx's `normalizeFlowRunTitle`: trimmed, and none when nothing is left.
    static func normalizeFlowRunTitle(_ value: String?) -> String? {
        guard let trimmed = value?.javaScriptTrimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `new Date(finishedAt).getTime() - new Date(startedAt).getTime()`.
    static func durationMs(from startedAt: String, to finishedAt: String) -> Double {
        guard let start = milliseconds(startedAt), let end = milliseconds(finishedAt) else { return .nan }
        return end - start
    }

    private static func milliseconds(_ iso: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { return nil }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    /// acpx's `isInlineSerializableText`: short enough, and on one line.
    static func isInlineSerializableText(_ units: [UInt16]) -> Bool {
        units.count <= 200 && !units.contains(0x0A)
    }

    /// The first eight hex digits of a SHA-256 of `text`.
    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// acpx's `stableShortHash`: the first eight hex digits of a SHA-1 of `value`.
    static func stableShortHash(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
            .description
    }

    /// The hex SHA-256 of `data`, as artifacts are named.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
