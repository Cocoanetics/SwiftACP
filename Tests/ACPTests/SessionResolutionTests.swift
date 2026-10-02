@testable import ACPXCore
@testable import acpxd
import Foundation
import Testing

/// The daemon resolves a session id as acpx's `resolveSessionRecord` does (#301): the record
/// filed under the id, else the one record whose id or ACP session id it is, else the one
/// whose id or ACP session id ends with it. Records have ids of their own since #307, so two
/// can share an agent's session id — such an id is refused, not answered with whichever record
/// came first. Ports the resolution cases of acpx's `session-lookup-freshness.test.ts`.
struct SessionResolutionTests {
    /// acpx's `withIndexedRecords` records: `first` under agent-a, `second` and `third` under
    /// agent-b, each with the ACP session id `native-<id>`, newest first.
    private func seedRecords() throws -> [SessionRecord] {
        try ["first", "second", "third"].enumerated().map { position, id in
            let record = SessionRecord(
                acpxRecordId: id, acpSessionId: "native-\(id)", agentCommand: position == 0 ? "agent-a" : "agent-b",
                cwd: position == 0 ? "/tmp/repo" : "/tmp/elsewhere", createdAt: "2026-01-01T00:00:00.000Z",
                lastUsedAt: "2026-01-0\(3 - position)T00:00:00.000Z")
            try SessionStore.writeRecord(record)
            return record
        }
    }

    /// What resolving `id` fails with — nothing, when it resolves.
    private func refusal(_ backend: ACPXDaemonBackend, _ id: String) async -> DaemonError? {
        await #expect(throws: DaemonError.self) { try await backend.resolveRecord(id) }
    }

    @Test func aRecordIdResolvesByItsFileAlone() async throws {
        try await withIsolatedStore {
            let records = try seedRecords()
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(try await backend.resolveRecord("first").acpxRecordId == "first")
            // acpx: "direct ID lookup does not return a record with an unrelated canonical ID" — a
            // copy of the record under another filename answers for neither id.
            try FileManager.default.copyItem(
                at: ACPXPaths.sessionRecordPath("first"), to: ACPXPaths.sessionRecordPath("unrelated"))
            #expect(await refusal(backend, "unrelated")?.localizedDescription == "no session found for id: unrelated")
            #expect(try await backend.resolveRecord(records[0].acpSessionId).acpxRecordId == "first")
            #expect(SessionStore.listSessions().count == 3)
        }
    }

    @Test func anAcpSessionIdResolvesTheOneRecordThatHasIt() async throws {
        try await withIsolatedStore {
            _ = try seedRecords()
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(try await backend.resolveRecord("native-second").acpxRecordId == "second")
            #expect(try await backend.showSession(sessionId: "native-third").id == "third")
        }
    }

    /// acpx: "canonical ID resolution detects hidden matches for native-first".
    @Test func anAcpSessionIdTwoRecordsShareIsRefused() async throws {
        try await withIsolatedStore {
            var records = try seedRecords()
            records[1].acpSessionId = records[0].acpSessionId
            try SessionStore.writeRecord(records[1])
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)

            let refused = await refusal(backend, "native-first")
            #expect(refused?.localizedDescription == "Multiple sessions match id: native-first")
            // The record's own id still resolves by its file.
            #expect(try await backend.resolveRecord("first").acpxRecordId == "first")

            // The tools that take an id say the same of it; acpx's SessionResolutionError names no
            // code of its own, so the failure is a plain runtime one, as a session not found is.
            let history = await #expect(throws: DaemonError.self) {
                try await backend.sessionHistory(sessionId: "native-first")
            }
            #expect(history?.localizedDescription == "Multiple sessions match id: native-first")
            let shown = await #expect(throws: DaemonError.self) {
                try await backend.showSession(sessionId: "native-first")
            }
            #expect(shown?.localizedDescription == "Multiple sessions match id: native-first")
            #expect(backend.toolFailure(for: DaemonError.multipleSessionsMatch("native-first")) == nil)
            // A tool that answers an unknown id with `false` still refuses one two records share.
            #expect(try await backend.cancelSession(sessionId: "nowhere") == false)
            let cancel = await #expect(throws: DaemonError.self) {
                try await backend.cancelSession(sessionId: "native-first")
            }
            #expect(cancel?.localizedDescription == "Multiple sessions match id: native-first")
        }
    }

    /// acpx: "ID resolution forgets old IDs and discovers changed IDs".
    @Test func aSuffixResolvesTheOneRecordWhoseIdEndsWithIt() async throws {
        try await withIsolatedStore {
            var records = try seedRecords()
            let previous = records[0].acpSessionId
            records[0].acpSessionId = "native-reconnected"
            try SessionStore.writeRecord(records[0])
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await refusal(backend, previous)?.localizedDescription == "no session found for id: \(previous)")
            #expect(try await backend.resolveRecord("reconnected").acpxRecordId == "first")
            #expect(try await backend.sessionHistory(sessionId: "reconnected").isEmpty)
        }
    }

    /// acpx: "canonical ID resolution detects hidden matches for first", by the suffix `-first`.
    @Test func aSuffixTwoRecordsShareIsRefused() async throws {
        try await withIsolatedStore {
            var records = try seedRecords()
            records[1].acpSessionId = records[0].acpSessionId
            try SessionStore.writeRecord(records[1])
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await refusal(backend, "-first")?.localizedDescription == "Session id is ambiguous: -first")
            #expect(try await backend.resolveRecord("first").acpxRecordId == "first")
        }
    }

    /// acpx: "exact canonical IDs take precedence over multiple suffix matches".
    @Test func anExactMatchOutranksTheSuffixMatches() async throws {
        try await withIsolatedStore {
            let records = try seedRecords()
            for (index, var record) in records.enumerated() {
                record.acpSessionId = index == 2 ? "shared-id" : "\(index)-shared-id"
                try SessionStore.writeRecord(record)
            }
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(try await backend.resolveRecord("shared-id").acpxRecordId == "third")
        }
    }

    /// Every id ends with the empty string: a blank id would resolve to a store's sole record by
    /// suffix. acpx never gets that far, its owner refusing a blank id at input validation
    /// (`owner-input.ts`); the daemon refuses it where it resolves ids (Codex on #310).
    @Test func aBlankIdIsRefusedBeforeItCanMatchTheSoleRecord() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            try SessionStore.writeRecord(SessionRecord(
                acpxRecordId: "only", acpSessionId: "native-only", agentCommand: "agent-a", cwd: "/tmp/repo",
                createdAt: now, lastUsedAt: now))
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(try await backend.resolveRecord("y").acpxRecordId == "only")
            for blank in ["", "  ", "\n"] {
                let refused = await refusal(backend, blank)
                #expect(refused?.localizedDescription == DaemonError.emptySessionId.localizedDescription)
            }
            let shown = await #expect(throws: DaemonError.self) { try await backend.showSession(sessionId: "") }
            #expect(shown?.localizedDescription == DaemonError.emptySessionId.localizedDescription)
            let closed = await #expect(throws: DaemonError.self) { try await backend.closeSession(sessionId: "") }
            #expect(closed?.localizedDescription == DaemonError.emptySessionId.localizedDescription)
            let cancelled = await #expect(throws: DaemonError.self) {
                try await backend.cancelSession(sessionId: "")
            }
            #expect(cancelled?.localizedDescription == DaemonError.emptySessionId.localizedDescription)
            #expect(SessionStore.loadRecord("only")?.closed != true)
        }
    }

    /// A record read again by its own id after the actor suspended — a close's re-read, a turn's
    /// once it holds the slot — is its file and nothing else, as acpx's `readSessionRecord` reads
    /// one: a file gone meanwhile is a miss, not the record whose id ends with the missing one,
    /// which the close would otherwise mark closed and the turn go on under (Codex on #310). A
    /// caller's id still resolves the survivor by suffix, as acpx's `resolveSessionRecord` does.
    @Test func aReloadByARecordsOwnIdReadsItsFileAlone() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            for id in ["first", "the-first"] {
                try SessionStore.writeRecord(SessionRecord(
                    acpxRecordId: id, acpSessionId: "native-\(id)", agentCommand: "agent-a", cwd: "/tmp/repo",
                    createdAt: now, lastUsedAt: now))
            }
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await backend.reloadRecord("first")?.acpxRecordId == "first")
            try FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath("first"))
            #expect(await backend.reloadRecord("first") == nil)
            #expect(try await backend.resolveRecord("first").acpxRecordId == "the-first")
            #expect(SessionStore.loadRecord("the-first")?.closed != true)
        }
    }

    /// acpx compares ids with JS `===` and `endsWith`: UTF-16 code units. Swift's `==` and
    /// `hasSuffix` compare by canonical equivalence, under which `e` plus a combining acute is
    /// the precomposed `é`, so a caller's id in the other normalization form would resolve a
    /// record acpx would not find (Codex on #310). The record's file, named by
    /// `safeSessionId`'s percent-encoding of each byte, never matched either way.
    @Test func anIdInAnotherNormalizationFormIsNotFound() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            try SessionStore.writeRecord(SessionRecord(
                acpxRecordId: "record-caf\u{e9}", acpSessionId: "native-caf\u{e9}", agentCommand: "agent-a",
                cwd: "/tmp/repo", createdAt: now, lastUsedAt: now))
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect("caf\u{e9}" == "cafe\u{301}", "the two forms are one string to Swift")
            // Precomposed, as the record has it: by file, exact ACP id and suffix.
            #expect(try await backend.resolveRecord("record-caf\u{e9}").acpxRecordId == "record-caf\u{e9}")
            #expect(try await backend.resolveRecord("native-caf\u{e9}").acpxRecordId == "record-caf\u{e9}")
            #expect(try await backend.resolveRecord("caf\u{e9}").acpxRecordId == "record-caf\u{e9}")
            // Decomposed: other code units, so no match, as acpx finds none.
            for other in ["record-cafe\u{301}", "native-cafe\u{301}", "cafe\u{301}"] {
                let refused = await refusal(backend, other)
                #expect(refused?.localizedDescription == "no session found for id: \(other)")
            }
        }
    }

    /// Blank is blank by JavaScript's `trim()` (acpx's `sessionId.trim().length === 0`), whose
    /// set differs from Foundation's `.whitespacesAndNewlines` both ways: U+200B (a format
    /// character) is an id to acpx, and U+FEFF is blank (Codex on #310).
    @Test func aBlankIdIsBlankByJavaScriptsTrim() async throws {
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            for blank in ["\u{FEFF}", "\u{2028}", " \u{3000} ", "\u{A0}\t"] {
                let refused = await refusal(backend, blank)
                #expect(refused?.localizedDescription == DaemonError.emptySessionId.localizedDescription)
            }
            // A one-character id, not a blank one: no record has it yet.
            #expect(await refusal(backend, "\u{200B}")?.localizedDescription == "no session found for id: \u{200B}")

            let now = nowISO()
            try SessionStore.writeRecord(SessionRecord(
                acpxRecordId: "x\u{200B}", acpSessionId: "native-x\u{200B}", agentCommand: "agent-a", cwd: "/tmp/repo",
                createdAt: now, lastUsedAt: now))
            #expect(try await backend.resolveRecord("x\u{200B}").acpxRecordId == "x\u{200B}")
            #expect(try await backend.resolveRecord("native-x\u{200B}").acpxRecordId == "x\u{200B}")
            #expect(try await backend.showSession(sessionId: "x\u{200B}").id == "x\u{200B}")
            #expect(try await backend.resolveRecord("\u{200B}").acpxRecordId == "x\u{200B}")
        }
    }

    /// `runPrompt` takes the id as sent, as acpx's owner does (`owner-input.ts` refuses a blank
    /// one by `trim()` and passes it on untrimmed): a one-character id of U+200B reaches its
    /// record, and `" id "` names no record `id`. A Foundation pre-trim did the opposite of both
    /// (Codex on #310).
    @Test(.timeLimit(.minutes(1))) func aPromptsSessionIdIsTakenAsSent() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            for id in ["x\u{200B}", "id"] {
                try SessionStore.writeRecord(SessionRecord(
                    acpxRecordId: id, acpSessionId: "native-\(id)", agentCommand: "/nonexistent/agent",
                    cwd: NSTemporaryDirectory(), createdAt: now, lastUsedAt: now))
            }
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            // Past resolution: the only thing left to fail is the record's agent, which cannot start.
            let past = await #expect(throws: (any Error).self) {
                try await backend.runPrompt(sessionId: "\u{200B}", text: "hi")
            }
            #expect(past.map { $0 is DaemonError } == false, "\(String(describing: past))")
            #expect(past?.localizedDescription.contains("/nonexistent/agent") == true)
            // Not trimmed to `id`: no record's id is, or ends with, `" id "`.
            let padded = await #expect(throws: DaemonError.self) {
                try await backend.runPrompt(sessionId: " id ", text: "hi")
            }
            #expect(padded?.localizedDescription == "no session found for id:  id ")
        }
    }

    @Test func anIdNoRecordHasIsNotFound() async throws {
        try await withIsolatedStore {
            _ = try seedRecords()
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            #expect(await refusal(backend, "nowhere")?.localizedDescription == "no session found for id: nowhere")
            #expect(await backend.reloadRecord("nowhere") == nil)
            #expect(try await backend.resolveRecordIfAny("nowhere") == nil)
        }
    }
}
