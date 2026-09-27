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

    // MARK: - ACP nodes

    /// acpx's `summarizePrompt`: the node's own detail, else `ACP: ` and the prompt's first
    /// line with anything in it, trimmed and cut at 120 UTF-16 units.
    static func summarizePrompt(_ promptText: [UInt16], explicitDetail: String?) -> WireJSON {
        if let explicitDetail, !explicitDetail.isEmpty { return .text(explicitDetail) }
        let lines = promptText.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard let line = lines.lazy.map({ SessionRecordParser.javaScriptTrimmed(Array($0)) }).first(where: {
            !$0.isEmpty
        }) else { return .text("Running ACP prompt") }
        let truncated = line.count > 120 ? Array(line.prefix(117)) + Array("...".utf16) : line
        return .string(Array("ACP: ".utf16) + truncated)
    }

    /// acpx's `createSessionBundleId`: the handle as a slug — `session` for none — and a
    /// short hash of the binding's key.
    static func createSessionBundleId(handle: String, key: String) -> String {
        let safeHandle = slugifyAsciiIdPart(handle)
        return "\(safeHandle.isEmpty ? "session" : safeHandle)-\(stableShortHash(key))"
    }

    /// acpx's `createSessionName`: a persistent session named for the flow, the handle,
    /// where it works, and the run.
    static func createSessionName(flowName: String, handle: String, cwd: String, runId: String) -> String {
        "\(flowName)-\(handle)-\(stableShortHash(cwd))-\(String(runId.suffix(8)))"
    }

    /// acpx's `findConversationDeltaStart`: the most of `after`'s first messages that are
    /// `before`'s last, as JSON writes them — where a turn's messages start in `after`, the
    /// conversation having been cut to its latest messages meanwhile or not.
    static func findConversationDeltaStart(_ before: [WireJSON], _ after: [WireJSON]) -> Int {
        let beforeText = before.map(\.stringified)
        let afterText = after.map(\.stringified)
        for overlap in stride(from: min(before.count, after.count), through: 0, by: -1) {
            let tail = beforeText.suffix(overlap)
            if Array(tail) == Array(afterText.prefix(overlap)) { return overlap }
        }
        return 0
    }

    /// acpx's `defaultSessionEventLog` for a session record.
    static func defaultSessionEventLog(_ recordId: String) -> WireJSON {
        .object([
            ("active_path", .text(ACPXPaths.sessionStreamPath(recordId).path)),
            ("segment_count", .number(Double(DEFAULT_EVENT_MAX_SEGMENTS))),
            ("max_segment_bytes", .number(Double(DEFAULT_EVENT_SEGMENT_MAX_BYTES))),
            ("max_segments", .number(Double(DEFAULT_EVENT_MAX_SEGMENTS))), ("last_write_error", .null)
        ])
    }

    /// The members of acpx's session `acpx` block `cloneSessionAcpxState` copies, in its order.
    static let clonedAcpxStateKeys = [
        "current_mode_id", "desired_mode_id", "desired_config_options", "current_model_id", "available_models",
        "available_model_names", "model_control", "available_commands", "config_options", "session_options"
    ]

    /// acpx's `createSyntheticSessionRecord`: a closed record of `binding`'s session, with
    /// the conversation — and the `acpx` block, when there is one — of `conversation`, an
    /// in-memory record as acpx holds it (``ACPXCore/SessionRecord/acpxRecord()``).
    static func createSyntheticSessionRecord(
        binding: FlowSessionBinding, createdAt: String, updatedAt: String, conversation: WireJSON, withAcpx: Bool,
        lastSeq: Int
    ) -> WireJSON {
        var acpx: WireJSON?
        if withAcpx {
            let state = conversation["acpx"]
            acpx = .object(clonedAcpxStateKeys.map { ($0, state?[$0]) })
        }
        return .object([
            ("schema", .text(SESSION_RECORD_SCHEMA)), ("acpxRecordId", .text(binding.acpxRecordId)),
            ("acpSessionId", .text(binding.acpSessionId)),
            ("agentSessionId", binding.agentSessionId.map(WireJSON.text)),
            ("agentCommand", .text(binding.agentCommand)),
            ("agentArgv", binding.agentArgv.map { .array($0.map(WireJSON.text)) }), ("cwd", .text(binding.cwd)),
            ("name", .text(binding.name)), ("createdAt", .text(createdAt)), ("lastUsedAt", .text(updatedAt)),
            ("lastSeq", .number(Double(lastSeq))), ("eventLog", defaultSessionEventLog(binding.acpxRecordId)),
            ("closed", .bool(true)), ("closedAt", .text(updatedAt)), ("title", conversation["title"]),
            ("messages", conversation["messages"]), ("updated_at", conversation["updated_at"]),
            ("cumulative_token_usage", conversation["cumulative_token_usage"]),
            ("cumulative_cost", conversation["cumulative_cost"]),
            ("request_token_usage", conversation["request_token_usage"]), ("acpx", acpx)
        ])
    }
}
