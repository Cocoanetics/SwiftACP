@testable import ACPXCore
import Foundation
import Testing

/// How records reach disk: privately, atomically, and without a temp name that a long
/// session id can push past the filesystem's component limit. Ports acpx's storage
/// hardening (0.13.0, 0.13.1, 0.16.0 — issue #24).
///
/// Serialized because these redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct SessionStoreWriteTests {
    private func record(id: String) -> SessionRecord {
        let now = nowISO()
        return SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: "codex", cwd: "/tmp",
            createdAt: now, lastUsedAt: now)
    }

    private func mode(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
    }

    @Test func recordsAndIndexAreOwnerOnly() async throws {
        try await withIsolatedStore {
            try SessionStore.writeRecord(record(id: "priv-1"))

            #expect(try mode(of: ACPXPaths.sessionRecordPath("priv-1")) == 0o600)
            #expect(try mode(of: ACPXPaths.sessionIndexPath) == 0o600)
        }
    }

    @Test func rewritingKeepsThePrivateModeAndTheNewContent() async throws {
        try await withIsolatedStore {
            var seed = record(id: "priv-2")
            try SessionStore.writeRecord(seed)
            seed.name = "renamed"
            try SessionStore.writeRecord(seed)

            #expect(SessionStore.loadRecord("priv-2")?.name == "renamed")
            #expect(try mode(of: ACPXPaths.sessionRecordPath("priv-2")) == 0o600)
        }
    }

    @Test func longSessionIdsStillWrite() async throws {
        try await withIsolatedStore {
            // 245 bytes + ".json" sits just inside the 255-byte component limit; the old
            // `<basename>.<pid>.<millis>.tmp` sidecar pushed it past.
            let id = String(repeating: "s", count: 245)
            try SessionStore.writeRecord(record(id: id))

            #expect(SessionStore.loadRecord(id)?.acpxRecordId == id)
        }
    }

    @Test func noTemporaryFilesSurviveAWrite() async throws {
        try await withIsolatedStore {
            try SessionStore.writeRecord(record(id: "tmp-1"))
            try SessionStore.writeRecord(record(id: "tmp-2"))

            let contents = try FileManager.default.contentsOfDirectory(
                atPath: ACPXPaths.sessionsDir.path)
            #expect(contents.filter { $0.hasSuffix(".tmp") }.isEmpty)
            // And the walk/listing side still sees both records.
            #expect(SessionStore.listSessions().count == 2)
        }
    }
}
