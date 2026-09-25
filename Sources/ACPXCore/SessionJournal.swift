import Foundation
import SwiftACP

/// acpx's session journal (`session/journal.ts`): what a session's event log keeps
/// besides its ACP messages — a `segment` anchor at the head of each segment, saying where
/// in the journal it starts, and `turn_started` / `turn_result` around each turn, keyed by
/// the turn's request id. acpx's `sessions watch` reads them.
public enum SessionJournal {
    /// acpx's `SESSION_JOURNAL_SCHEMA`.
    public static let schema = "acpx.session.journal.v1"

    /// How a turn ended, as `turn_result` carries it: acpx's `SessionWatchResult`.
    public enum TurnResult: Sendable, Equatable {
        /// The prompt answered: `completed`, or `cancelled` when that is its stop reason,
        /// with the answer's `_meta` when it had one.
        case settled(stopReason: String, meta: WireJSON?)
        /// The turn failed, its error as acpx's `normalizeOutputError` gives it.
        case failed(message: String, code: String?, detailCode: String?, retryable: Bool?)

        /// What acpx records for a turn whose owner went down before it ended.
        static let outcomeUnknown = TurnResult.failed(
            message: "The previous owner ended without recording a settled result; the turn outcome is unknown.",
            code: nil, detailCode: "WATCH_OUTCOME_UNKNOWN", retryable: false)

        var json: WireJSON {
            switch self {
            case let .settled(stopReason, meta):
                var members: [WireJSON.Member] = [
                    .init("status", .text(stopReason == "cancelled" ? "cancelled" : "completed")),
                    .init("stopReason", .text(stopReason))
                ]
                if let meta { members.append(.init("_meta", meta)) }
                return .object(members)
            case let .failed(message, code, detailCode, retryable):
                var error: [WireJSON.Member] = [.init("message", .text(message))]
                if let code { error.append(.init("code", .text(code))) }
                if let detailCode { error.append(.init("detailCode", .text(detailCode))) }
                if let retryable { error.append(.init("retryable", .bool(retryable))) }
                return .object([.init("status", .text("failed")), .init("error", .object(error))])
            }
        }
    }

    static func anchor(recordId: String, sequence: Int, messageSequence: Int, requestId: String?) -> WireJSON {
        record("segment", [
            .init("record_id", .text(recordId)),
            .init("sequence", .number(Double(sequence))),
            .init("message_sequence", .number(Double(messageSequence))),
            .init("request_id", requestId.map { .text($0) } ?? .null)
        ])
    }

    static func turnStarted(_ requestId: String) -> WireJSON {
        record("turn_started", [.init("request_id", .text(requestId))])
    }

    static func turnResult(_ requestId: String, _ result: TurnResult) -> WireJSON {
        record("turn_result", [.init("request_id", .text(requestId)), .init("result", result.json)])
    }

    private static func record(_ type: String, _ members: [WireJSON.Member]) -> WireJSON {
        .object([.init("schema", .text(schema)), .init("type", .text(type))] + members)
    }

    /// Where a session's journal left off: acpx's `SessionJournalReader.readTail`.
    struct Tail {
        /// Journal records so far: messages and turn records, not anchors.
        var sequence = 0
        /// Messages so far, when a segment is anchored.
        var messageSequence: Int?
        /// The turn the journal has started and not ended.
        var requestId: String?
        /// The active segment's size, whether it is anchored, and whether it ends in part
        /// of a line.
        var activeSize = 0
        var activeAnchored = false
        var activePartial = false
    }

    /// The newest anchored segment, read through, and the active segment as it is: the
    /// segments are read newest first, up to the first with an anchor. Lines before a
    /// segment's anchor are passed over; after it, one that is neither an ACP message nor
    /// a journal record, or a record out of place, is corruption (``SessionJournalError``).
    static func readTail(recordId: String, maxSegments: Int) throws -> Tail {
        let active = ACPXPaths.sessionStreamPath(recordId).path
        let paths = [active] + (1...max(maxSegments, 1)).map {
            ACPXPaths.sessionStreamSegmentPath(recordId, segment: $0).path
        }
        var tail = SegmentState()
        var activeState = SegmentState()
        for path in paths {
            guard try SessionArchive.isPresentSegment(path) else { continue }
            let data: Data
            do {
                data = try SessionArchive.readFile(at: path)
            } catch let failure as SessionArchive.Failure where failure.code == ENOENT {
                continue
            }
            var state = SegmentState()
            try state.consume(data, recordId: recordId)
            if path == active { activeState = state }
            if state.firstSequence != nil {
                tail = state
                break
            }
        }
        return Tail(
            sequence: tail.sequence, messageSequence: tail.firstSequence == nil ? nil : tail.messageSequence,
            requestId: tail.requestId, activeSize: activeState.size, activeAnchored: activeState.firstSequence != nil,
            activePartial: activeState.partial)
    }

    /// What reading one segment found: acpx's `SegmentState`.
    private struct SegmentState {
        var size = 0
        var partial = false
        /// The anchor's sequence, once the segment's anchor is read.
        var firstSequence: Int?
        var sequence = 0
        var messageSequence = 0
        var requestId: String?

        mutating func consume(_ data: Data, recordId: String) throws {
            size = data.count
            var start = data.startIndex
            while let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
                try consumeLine(String(decoding: data[start..<end], as: UTF8.self), recordId: recordId)
                start = end + 1
            }
            partial = start < data.endIndex
        }

        /// acpx's `decodeJournalLine` and `consumeLine`.
        private mutating func consumeLine(_ line: String, recordId: String) throws {
            let anchored = firstSequence != nil
            guard let value = try? WireJSON.parse(line) else {
                if anchored { throw SessionJournalError.corrupt("Invalid complete line in session journal") }
                return
            }
            if SessionArchive.isACPMessage(value) {
                guard anchored else { return }
                try advance()
                messageSequence += 1
                return
            }
            if let marker = Marker(value) {
                try consume(marker, recordId: recordId)
            } else if anchored || value.hasMember("schema") {
                throw SessionJournalError.corrupt("Invalid record in session journal")
            }
        }

        private mutating func consume(_ marker: Marker, recordId: String) throws {
            if case let .segment(anchorRecordId, sequence, messageSequence, requestId) = marker {
                guard firstSequence == nil, anchorRecordId == recordId else {
                    throw SessionJournalError.corrupt("Invalid session journal segment anchor")
                }
                (firstSequence, self.sequence, self.messageSequence) = (sequence, sequence, messageSequence)
                self.requestId = requestId
                return
            }
            guard firstSequence != nil else {
                throw SessionJournalError.corrupt("Session journal lifecycle record has no segment anchor")
            }
            try advance()
            switch marker {
            case .turnStarted(let id):
                requestId = id
            case .turnResult(let id):
                guard requestId == id else {
                    throw SessionJournalError.corrupt("Session journal result does not match the active request")
                }
                requestId = nil
            case .segment:
                break
            }
        }

        private mutating func advance() throws {
            sequence += 1
            guard sequence <= Marker.maxSafeInteger else {
                throw SessionJournalError.corrupt("Session journal sequence exceeds its supported range")
            }
        }
    }

    /// A journal record, as acpx's `markerSchema` accepts it.
    private enum Marker {
        case segment(recordId: String, sequence: Int, messageSequence: Int, requestId: String?)
        case turnStarted(String)
        case turnResult(String)

        static let maxSafeInteger = 9_007_199_254_740_991

        init?(_ value: WireJSON) {
            guard case .object = value, value["schema"]?.stringValue == SessionJournal.schema else { return nil }
            switch value["type"]?.stringValue {
            case "segment":
                guard let recordId = value["record_id"]?.stringValue,
                      let sequence = Self.sequence(value["sequence"]),
                      let messageSequence = Self.sequence(value["message_sequence"]),
                      let requestId = value["request_id"], requestId == .null || requestId.stringValue != nil
                else { return nil }
                self = .segment(
                    recordId: recordId, sequence: sequence, messageSequence: messageSequence,
                    requestId: requestId.stringValue)
            case "turn_started":
                guard let id = value["request_id"]?.stringValue, !id.isEmpty else { return nil }
                self = .turnStarted(id)
            case "turn_result":
                guard let id = value["request_id"]?.stringValue, !id.isEmpty,
                      let result = value["result"], Self.isResult(result)
                else { return nil }
                self = .turnResult(id)
            default:
                return nil
            }
        }

        /// A whole number from 0 to `Number.MAX_SAFE_INTEGER`.
        private static func sequence(_ value: WireJSON?) -> Int? {
            guard case .number(let number)? = value, number >= 0, number <= Double(maxSafeInteger),
                  number == number.rounded()
            else { return nil }
            return Int(number)
        }

        /// acpx's `resultSchema`: a settled result, or a failed one with its error.
        private static func isResult(_ result: WireJSON) -> Bool {
            guard case .object = result else { return false }
            switch result["status"]?.stringValue {
            case "completed", "cancelled":
                let stopReasonFits = result["stopReason"].map { $0.stringValue != nil } ?? true
                let metaFits = result["_meta"].map { meta in
                    if case .object = meta { return true }
                    return meta == .null
                } ?? true
                return stopReasonFits && metaFits
            case "failed":
                guard let error = result["error"], case .object = error, error["message"]?.stringValue != nil
                else { return false }
                let textsFit = ["code", "detailCode"].allSatisfy { key in
                    error[key].map { $0.stringValue != nil } ?? true
                }
                let retryableFits = error["retryable"].map { value in
                    if case .bool = value { return true }
                    return false
                } ?? true
                return textsFit && retryableFits
            default:
                return false
            }
        }
    }
}

/// acpx's `SessionWatchError`: the journal is not as its writer leaves it. A turn that
/// finds its session's journal so fails before it starts, as acpx's does.
public struct SessionJournalError: Error, OutputErrorMeta, LocalizedError, Equatable {
    /// `WATCH_JOURNAL_CORRUPT`, or another of acpx's `WATCH_*` codes.
    public let code: String
    public let message: String

    static func corrupt(_ message: String) -> SessionJournalError {
        SessionJournalError(code: "WATCH_JOURNAL_CORRUPT", message: message)
    }

    public var errorDescription: String? { message }
    public var outputCode: String? { code.hasPrefix("WATCH_CURSOR_") ? "USAGE" : "RUNTIME" }
    public var detailCode: String? { code }
    public var origin: String? { "runtime" }
    public var retryable: Bool? { false }
}

/// acpx's journal write failure: a turn whose journal cannot be written fails with
/// `Session journal write failed: <why>`.
public struct SessionJournalWriteError: Error, OutputErrorMeta, LocalizedError {
    public let underlying: Error

    public var errorDescription: String? { "Session journal write failed: \(TurnFailure.message(of: underlying))" }
    public var outputCode: String? { "RUNTIME" }
    public var detailCode: String? { "SESSION_JOURNAL_WRITE_FAILED" }
    public var origin: String? { "runtime" }
    public var retryable: Bool? { false }
}
