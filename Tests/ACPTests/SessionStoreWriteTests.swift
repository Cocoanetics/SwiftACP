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

    @Test func recordsAndTheirDirectoryAreOwnerOnly() async throws {
        try await withIsolatedStore {
            try SessionStore.writeRecord(record(id: "priv-1"))

            #expect(try mode(of: ACPXPaths.sessionRecordPath("priv-1")) == 0o600)
            #expect(try mode(of: ACPXPaths.sessionsDir) == 0o700)
        }
    }

    /// The upgrade case: a store created before the store went owner-only keeps its
    /// directory, and `createDirectory` applies `attributes` only when it creates one.
    @Test func anExistingSessionsDirectoryIsTightened() async throws {
        try await withIsolatedStore {
            try FileManager.default.createDirectory(
                at: ACPXPaths.sessionsDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])

            try SessionStore.writeRecord(record(id: "upgrade-1"))

            #expect(try mode(of: ACPXPaths.sessionsDir) == 0o700)
        }
    }

    /// Event logs are the wire transcript — as private as the record beside them, and
    /// they must not create the directory at a looser mode either.
    @Test func eventLogsAreOwnerOnly() async throws {
        try await withIsolatedStore {
            var seed = record(id: "log-1")
            var writer = try SessionEventLogWriter.open(record: &seed)
            try writer.append([Data(#"{"jsonrpc":"2.0","method":"session/update"}"#.utf8)], into: &seed)

            let logMode = try mode(of: ACPXPaths.sessionStreamPath("log-1"))
            let directoryMode = try mode(of: ACPXPaths.sessionsDir)
            #expect(logMode == 0o600)
            #expect(directoryMode == 0o700)
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
