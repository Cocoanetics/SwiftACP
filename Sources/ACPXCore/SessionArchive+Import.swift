import Foundation
import SwiftACP

// Taking a session in from an archive (acpx's `importSession`). Split from
// `SessionArchive.swift`, which writes one.
extension SessionArchive {
    /// A session imported: its new record id and the directory it runs in.
    public struct Imported: Equatable, Sendable {
        public let recordId: String
        public let cwd: String
    }

    /// Import the archive at `path` as a new session, as acpx's `importSession` does.
    ///
    /// - Parameters:
    ///   - name: the session's name; the archive's when `nil`.
    ///   - cwd: where the session runs, resolved already; the archive's, under `home`
    ///     when relative, when `nil`.
    ///   - expectedAgentName: the agent it is imported for, when named.
    ///   - expectedAgentCommand: that agent's command, which the archive's must be.
    public static func importArchive(
        at path: String, name: String?, cwd: String?, expectedAgentName: String?,
        expectedAgentCommand: String?, home: String = ACPXPaths.home.path
    ) throws -> Imported {
        let archive = try readArchive(at: path)
        guard let state = archive["session"]?["state"], var record = SessionStore.record(from: state) else {
            throw Refusal("Invalid session export archive: session.state is not a session record", "invalid-archive")
        }
        try checkAgent(of: archive, record: &record, name: expectedAgentName, command: expectedAgentCommand)
        // Nothing an archive says is run here but the agent's own command: no MCP servers
        // come with it (SwiftACP's archives carry none), so it runs the config's, as in acpx.
        record.acpx?.mcpServers = nil
        // Made as acpx makes it here, with the default mode: writing the session makes the
        // sessions directory owner-only, but not the one above it.
        try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
        let cwdRelative = archive["session"]?["cwd_relative"]?.stringValue ?? ""
        let resolvedCwd = cwd.map(NodePath.resolve)
            ?? (cwdRelative.hasPrefix("/") ? cwdRelative : NodePath.join(home, cwdRelative))
        var recordId = UUID().uuidString.lowercased()
        while FileManager.default.fileExists(atPath: ACPXPaths.sessionRecordPath(recordId).path) {
            recordId = UUID().uuidString.lowercased()
        }
        var history: [WireJSON] = []
        if case .array(let items)? = archive["history"] { history = items }
        let imported = importedRecord(
            record, from: archive, id: recordId, cwd: resolvedCwd, name: name, historyCount: history.count)
        if SessionStore.findSession(
            agentCommand: imported.agentCommand, cwd: imported.cwd, name: imported.name) != nil {
            throw Refusal(
                "A session already exists for the import destination scope; pass --name or --cwd to import a "
                    + "separate copy", "session-scope-exists")
        }
        if SessionStore.listSessions().contains(where: { $0.acpSessionId == imported.acpSessionId }) {
            throw Refusal(
                "A local session already uses this provider session id; prune or remove the existing record "
                    + "before importing this archive", "session-provider-exists")
        }
        if !history.isEmpty {
            let lines = history.map(\.stringified).joined(separator: "\n") + "\n"
            try writeFile(Data(lines.utf8), to: ACPXPaths.sessionStreamPath(recordId).path, privateDirectory: true)
        }
        // As acpx: a record others can find already has all the history it came with.
        try SessionStore.writeRecord(imported)
        return Imported(recordId: recordId, cwd: resolvedCwd)
    }

    /// The archive at `path`, read and checked as acpx's `parseArchive` checks it.
    static func readArchive(at path: String) throws -> WireJSON {
        let data = try readFile(at: path)
        let archive: WireJSON
        do {
            archive = try WireJSON.parse(String(decoding: data, as: UTF8.self))
        } catch let error as WireJSON.SyntaxError {
            throw Refusal("Invalid session export archive JSON: \(error.message)", "invalid-archive")
        }
        let version = { () -> WireJSON? in
            guard case .object = archive else { return nil }
            return archive["format_version"]
        }()
        guard version == .number(Double(formatVersion)) else {
            throw Refusal(
                "Unsupported session export format_version \(javaScriptString(version)); supported version is "
                    + "\(formatVersion)", "unsupported-format-version")
        }
        if let issue = firstIssue(in: archive) {
            throw Refusal("Invalid session export archive: \(issue)", "invalid-archive")
        }
        return archive
    }

    /// acpx's `exportedSessionSchema`: the first way `archive` does not fit it, in zod's
    /// words, in the order zod checks — or `nil`.
    static func firstIssue(in archive: WireJSON) -> String? {
        func expected(_ type: String, _ value: WireJSON?) -> String {
            "Invalid input: expected \(type), received \(zodType(of: value))"
        }
        for key in ["exported_at", "exported_by"] {
            guard case .string? = archive[key] else { return expected("string", archive[key]) }
        }
        guard let session = archive["session"], case .object = session else {
            return expected("object", archive["session"])
        }
        // Its strings, in the schema's order: `name` may be null, and three may be absent.
        let fields = [
            "record_id", "name", "agent", "agent_name", "cwd_relative", "cwd_original", "cwd_absolute_original",
            "created_at", "updated_at"
        ]
        let optional: Set = ["agent_name", "cwd_original", "cwd_absolute_original"]
        for field in fields {
            switch session[field] {
            case .string?: continue
            case .null? where field == "name": continue
            case nil where optional.contains(field): continue
            case let other: return expected("string", other)
            }
        }
        // `state` takes anything, but must be there: zod calls its type "nonoptional".
        if session["state"] == nil { return expected("nonoptional", nil) }
        guard case .array? = archive["history"] else { return expected("array", archive["history"]) }
        return nil
    }

    /// The type zod names for `value` (`nil` for absent).
    private static func zodType(of value: WireJSON?) -> String {
        switch value {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool?: return "boolean"
        case .number?: return "number"
        case .string?: return "string"
        case .array?: return "array"
        case .object?: return "object"
        }
    }

    /// JavaScript's `String(value)`.
    static func javaScriptString(_ value: WireJSON?) -> String {
        switch value {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool(let flag)?: return flag ? "true" : "false"
        case .number(let number)?: return WireJSON.javaScriptString(for: number)
        case .string(let units)?: return String(decoding: units, as: UTF16.self)
        case .array(let items)?:
            return items.map { item in item == .null ? "" : javaScriptString(item) }.joined(separator: ",")
        case .object?: return "[object Object]"
        }
    }

    /// acpx's `assertExpectedAgentCommand`: the archive's agent, and its record's, must be
    /// the one the session is imported for — or look like the built-in agent named — and
    /// the record then runs that one's command.
    private static func checkAgent(
        of archive: WireJSON, record: inout SessionRecord, name: String?, command: String?
    ) throws {
        guard let command, !command.isEmpty else { return }
        let expectedName = normalizedAgentName(name)
        let archiveName = normalizedAgentName(archive["session"]?["agent_name"]?.stringValue)
        let archiveCommand = archive["session"]?["agent"]?.stringValue ?? ""
        func matches(_ archived: String) -> Bool {
            archived == command || expectedName.map { looksLikeBuiltIn(archived, agent: $0) } == true
        }
        let namesAgree = (archiveCommand == command && record.agentCommand == command) || archiveName == nil
            || expectedName == nil || archiveName == expectedName
        guard matches(archiveCommand), matches(record.agentCommand), namesAgree else {
            throw Refusal("Session export archive agent does not match the requested agent", "agent-mismatch")
        }
        record.agentCommand = command
    }

    /// acpx's `commandLooksLikeBuiltInAgent`.
    private static func looksLikeBuiltIn(_ command: String, agent: String) -> Bool {
        let package: String
        switch agent {
        case "pi": package = "pi-acp"
        case "codex": package = "@agentclientprotocol/codex-acp"
        case "claude": package = "@agentclientprotocol/claude-agent-acp"
        default: return false
        }
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: package) + "(?:@|\\s|$)"
        return command.javaScriptTrimmed.range(of: pattern, options: .regularExpression) != nil
    }

    /// acpx's `buildImportedRecord`: the archive's record under a new id, at `cwd`, with
    /// nothing of how its agent last ran, a fresh event log and where it came from.
    private static func importedRecord(
        _ source: SessionRecord, from archive: WireJSON, id: String, cwd: String, name: String?,
        historyCount: Int
    ) -> SessionRecord {
        var record = source
        record.acpxRecordId = id
        record.cwd = cwd
        record.name = name ?? archive["session"]?["name"]?.stringValue
        record.closed = false
        record.closedAt = nil
        record.pid = nil
        record.agentStartedAt = nil
        record.lastAgentExitCode = nil
        record.lastAgentExitSignal = nil
        record.lastAgentExitAt = nil
        record.lastAgentDisconnectReason = nil
        var eventLog = SessionEventLog(recordId: id)
        eventLog.segmentCount = historyCount > 0 ? 1 : source.eventLog.segmentCount
        eventLog.maxSegmentBytes = source.eventLog.maxSegmentBytes
        eventLog.maxSegments = source.eventLog.maxSegments
        record.eventLog = eventLog
        let cwdRelative = archive["session"]?["cwd_relative"]?.stringValue ?? ""
        record.importedFrom = SessionRecord.ImportedFrom(
            recordId: archive["session"]?["record_id"]?.stringValue ?? "",
            cwdOriginal: archive["session"]?["cwd_original"]?.stringValue ?? cwdRelative,
            exportedBy: archive["exported_by"]?.stringValue ?? "",
            exportedAt: archive["exported_at"]?.stringValue ?? "")
        return record
    }
}
