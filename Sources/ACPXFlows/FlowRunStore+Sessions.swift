import ACPXCore
import Foundation
import SwiftACP

// The session half of acpx's `FlowRunStore` (`src/flows/store.ts`, v0.19.3): each session
// an ACP node's turns ran in, under `sessions/<bundleId>/` — its binding, its record as
// the bundle keeps it, and every ACP message of its turns. Split from `FlowRunStore.swift`
// to keep each file inside the 500-line limit.
extension FlowRunStore {
    /// acpx's `sessionDirPath`.
    static func sessionDirPath(_ bundleId: String) -> String {
        "sessions/\(bundleId)"
    }

    /// acpx's `ensureSessionBundle`: the session's directory, its `binding.json` as the
    /// binding is now, its `events.ndjson`, and — given one — its `record.json`. The first
    /// time, the session's entry in the manifest, its binding as it was then kept as an
    /// artifact, and a `session_bound` event.
    mutating func ensureSessionBundle(
        _ runDir: URL, _ state: FlowRunState, _ binding: FlowSessionBinding, record: WireJSON? = nil
    ) throws {
        let directory = Self.sessionDirPath(binding.bundleId)
        let sessionDir = runDir.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.writeJSON(binding.wire, to: sessionDir.appendingPathComponent("binding.json"))
        try Self.append(Data(), to: sessionDir.appendingPathComponent("events.ndjson"))
        if let record { try writeSessionRecord(runDir, binding, record) }

        var manifest = currentManifest(state)
        guard case .array(var entries)? = manifest["sessions"],
            !entries.contains(where: { $0["id"]?.stringValue == binding.bundleId })
        else { return }
        let bindingArtifact = try writeArtifact(
            runDir, state, content: .value(.json(binding.wire)), mediaType: "application/json", extension: "json",
            emitTrace: false)
        entries.append(.object([
            ("id", .text(binding.bundleId)), ("handle", .text(binding.handle)),
            ("bindingPath", .text("\(directory)/binding.json")), ("recordPath", .text("\(directory)/record.json")),
            ("eventsPath", .text("\(directory)/events.ndjson"))
        ]))
        manifest["sessions"] = .array(entries)
        self.manifest = manifest
        try Self.writeJSON(manifest.wire, to: runDir.appendingPathComponent("manifest.json"))
        try appendTrace(
            runDir, state, scope: "session", type: "session_bound", sessionId: binding.bundleId,
            payload: .object([
                ("sessionId", .text(binding.bundleId)), ("handle", .text(binding.handle)),
                ("bindingArtifact", bindingArtifact.wire)
            ]))
    }

    /// acpx's `writeSessionRecord`: `record` as the bundle keeps it
    /// (`createBundledSessionRecord`) — its sequence the last event the bundle has written
    /// of the session, its event log the bundle's one file.
    func writeSessionRecord(_ runDir: URL, _ binding: FlowSessionBinding, _ record: WireJSON) throws {
        let directory = Self.sessionDirPath(binding.bundleId)
        let persisted = sessionSequences.persisted(Self.sessionKey(runDir, binding.bundleId))
        let eventLog = (record["eventLog"] ?? .object([WireJSON.Member]()))
            .assigning("active_path", .text("\(directory)/events.ndjson"))
            .assigning("segment_count", .number(1))
            .assigning("max_segments", .number(1))
        let bundled = record.assigning("lastSeq", .number(Double(persisted))).assigning("eventLog", eventLog)
        try Self.writeJSON(bundled, to: runDir.appendingPathComponent("\(directory)/record.json"))
    }

    /// Where a turn's ACP messages go (acpx's `appendSessionEvent`), numbered on from the
    /// session's last in the bundle.
    func sessionEventLog(_ runDir: URL, _ binding: FlowSessionBinding) -> FlowSessionEventLog {
        FlowSessionEventLog(
            file: runDir.appendingPathComponent("\(Self.sessionDirPath(binding.bundleId))/events.ndjson"),
            key: Self.sessionKey(runDir, binding.bundleId), sequences: sessionSequences)
    }

    /// acpx's `${runDir}::${bundleId}`, which a session's event numbers are kept by.
    static func sessionKey(_ runDir: URL, _ bundleId: String) -> String {
        "\(runDir.path)::\(bundleId)"
    }
}

/// Each bundled session's event numbers (acpx's `sessionSeqByBundle`): those handed out,
/// and the last written.
final class FlowSessionSequences: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [String: (allocated: Int, persisted: Int)] = [:]

    func allocate(_ key: String) -> Int {
        lock.withLock {
            let next = (sequences[key]?.allocated ?? 0) + 1
            sequences[key, default: (0, 0)].allocated = next
            return next
        }
    }

    func markPersisted(_ key: String, _ seq: Int) {
        lock.withLock { sequences[key, default: (0, 0)].persisted = max(sequences[key]?.persisted ?? 0, seq) }
    }

    func persisted(_ key: String) -> Int {
        lock.withLock { sequences[key]?.persisted ?? 0 }
    }
}

/// One session's `events.ndjson` in the bundle, as a turn's messages are appended to it:
/// acpx's `appendSessionEvent`, one `{seq, at, direction, message}` line each, the number
/// taken as the message comes and published once its line is written.
struct FlowSessionEventLog: Sendable {
    let file: URL
    let key: String
    let sequences: FlowSessionSequences

    /// Append `message`, returning its number.
    func append(outbound: Bool, _ message: WireJSON) throws -> Int {
        let seq = sequences.allocate(key)
        let line: WireJSON = .object([
            ("seq", .number(Double(seq))), ("at", .text(nowISO())),
            ("direction", .text(outbound ? "outbound" : "inbound")), ("message", message)
        ])
        try FlowRunStore.append(Data((line.stringified + "\n").utf8), to: file)
        sequences.markPersisted(key, seq)
        return seq
    }
}

extension WireJSON {
    /// This object with `key` set as a JavaScript assignment sets it: in place when it is
    /// there, else last.
    func assigning(_ key: String, _ value: WireJSON) -> WireJSON {
        guard case .object(let members) = self else { return self }
        if hasMember(key) { return replacing(key, with: value) }
        return .object(members + [Member(key, value)])
    }
}
