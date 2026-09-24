@testable import ACPXCore
import Foundation
import Testing

/// Lookups resolve from the saved records, not from cached metadata: a record edited
/// outside the store is seen immediately, a record whose filename disagrees with its own
/// id is ignored, and a legacy `index.json` has no say. Ports acpx 0.19.0's
/// `scanSessionRecords` / record-resolved queries (issue #27).
///
/// Serialized because these redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct SessionDiscoveryTests {
    private func seed(
        id: String, cwd: String, name: String? = nil, agent: String = "codex",
        lastUsedAt: String? = nil
    ) throws -> SessionRecord {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: agent, cwd: cwd,
            createdAt: now, lastUsedAt: lastUsedAt ?? now)
        record.name = name
        try SessionStore.writeRecord(record)
        return record
    }

    /// Rewrite a record's file behind the store's back — what a real npm `acpx`, a second
    /// process, or a hand edit does. Nothing here updates any cached view.
    private func writeBehindTheStore(_ record: SessionRecord, to recordId: String) throws {
        try SessionRecordSerializer.data(for: record).write(to: ACPXPaths.sessionRecordPath(recordId))
    }

    @Test func anExternallyEditedRecordIsSeenImmediately() async throws {
        try await withIsolatedStore {
            var record = try seed(id: "ext-1", cwd: "/tmp/original")
            #expect(
                SessionStore.findSession(
                    agentCommand: "codex", cwd: "/tmp/original", name: nil)?.acpxRecordId == "ext-1")

            // Same filename, new contents: a file-set check cannot notice this.
            record.cwd = "/tmp/moved"
            try writeBehindTheStore(record, to: "ext-1")

            #expect(SessionStore.findSession(agentCommand: "codex", cwd: "/tmp/original", name: nil) == nil)
            #expect(
                SessionStore.findSession(
                    agentCommand: "codex", cwd: "/tmp/moved", name: nil)?.acpxRecordId == "ext-1")
        }
    }

    @Test func aRecordClosedExternallyStopsMatching() async throws {
        try await withIsolatedStore {
            var record = try seed(id: "ext-2", cwd: "/tmp/work")
            record.closed = true
            try writeBehindTheStore(record, to: "ext-2")

            #expect(SessionStore.findSession(agentCommand: "codex", cwd: "/tmp/work", name: nil) == nil)
            #expect(
                SessionStore.findSession(
                    agentCommand: "codex", cwd: "/tmp/work", name: nil, includeClosed: true) != nil)
        }
    }

    @Test func aCopiedRecordCannotAnswerForTheRecordItNames() async throws {
        try await withIsolatedStore {
            let record = try seed(id: "orig-1", cwd: "/tmp/work")
            // A copy under someone else's name still claims `orig-1` inside.
            try writeBehindTheStore(record, to: "copy-1")

            #expect(SessionStore.loadRecord("copy-1") == nil)
            #expect(SessionStore.scanRecords().map(\.acpxRecordId) == ["orig-1"])
            #expect(SessionStore.listSessions().count == 1)
        }
    }

    @Test func aLegacyIndexFileIsIgnored() async throws {
        try await withIsolatedStore {
            _ = try seed(id: "idx-1", cwd: "/tmp/work")
            try Data(#"{"schema":"acpx.session-index.v1","files":[],"entries":[]}"#.utf8)
                .write(to: ACPXPaths.sessionsDir.appendingPathComponent("index.json"))

            // An empty legacy index claims there are no sessions; the records say otherwise.
            #expect(SessionStore.listSessions().map(\.acpxRecordId) == ["idx-1"])
            #expect(SessionStore.scanRecords().count == 1)
        }
    }

    @Test func theNearestDirectoryWinsAndTiesGoToTheNewest() async throws {
        try await withIsolatedStore {
            let root = "/tmp/repo"
            let nested = "/tmp/repo/pkg"
            _ = try seed(id: "far", cwd: root, lastUsedAt: "2030-01-01T00:00:00.000Z")
            _ = try seed(id: "near", cwd: nested, lastUsedAt: "2000-01-01T00:00:00.000Z")

            // Nearest wins even though the ancestor was used far more recently.
            #expect(
                SessionStore.findSessionByDirectoryWalk(
                    agentCommand: "codex", cwd: nested, name: nil,
                    boundary: root)?.acpxRecordId == "near")

            // At equal distance, the most recently used record wins.
            _ = try seed(id: "newer", cwd: nested, lastUsedAt: "2031-01-01T00:00:00.000Z")
            #expect(
                SessionStore.findSessionByDirectoryWalk(
                    agentCommand: "codex", cwd: nested, name: nil,
                    boundary: root)?.acpxRecordId == "newer")
        }
    }
}
