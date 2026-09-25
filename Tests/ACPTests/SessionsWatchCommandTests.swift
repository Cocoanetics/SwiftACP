@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// `acpx sessions watch` as acpx 0.19.1's (#59): a journal acpx wrote, watched, prints
/// what acpx printed for it; the owner is looked at as acpx looks at it; and a history
/// read back has its reads suppressed as acpx suppresses them.
@Suite(.serialized) struct SessionsWatchCommandTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/watch")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// `acpx <options> sessions watch` over the journal acpx wrote for two turns — one
    /// that answered, one that failed — its session closed. It was written in `/tmp/watch`
    /// by an agent run as `probe`.
    struct Watched {
        var code: Int32
        var out: String
        var err: String
    }

    private func watch(_ options: [String]) async throws -> Watched {
        try await withIsolatedStore {
            let now = nowISO()
            var record = SessionRecord(
                acpxRecordId: "journal-session", acpSessionId: "journal-session", agentCommand: "probe-agent",
                cwd: "/tmp/watch", createdAt: now, lastUsedAt: now)
            record.closed = true
            try SessionStore.writeRecord(record)
            try fixture("journal-session.stream.ndjson").write(
                to: ACPXPaths.sessionStreamPath("journal-session"), atomically: true, encoding: .utf8)
            let arguments = ["--agent", "probe-agent", "--cwd", "/tmp/watch"] + options
            let capture = Console.Capture()
            // The command blocks its thread until it is done, as the CLI does: a thread of its own.
            let code: Int32 = await withCheckedContinuation { continuation in
                Thread {
                    let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
                    continuation.resume(returning: code)
                }.start()
            }
            return Watched(code: code, out: capture.out, err: capture.err)
        }
    }

    @Test(arguments: [
        ([String](), "watch-text.txt"),
        (["--format", "json"], "watch-json.ndjson"),
        (["--format", "quiet"], "watch-quiet.txt"),
        (["--format", "json", "sessions", "watch", "--cursor", "WyJqb3VybmFsLXNlc3Npb24iLDJd"],
         "watch-json-after-second.ndjson")
    ])
    func aWatchPrintsWhatAcpxPrinted(options: [String], expected: String) async throws {
        let arguments = options.contains("watch") ? options : options + ["sessions", "watch"]
        let watched = try await watch(arguments)
        #expect(watched.code == ExitCodes.success, "\(watched.err)")
        #expect(watched.out == (try fixture(expected)))
    }

    @Test func anInvalidCursorIsAUsageError() async throws {
        let watched = try await watch(["sessions", "watch", "--cursor", "abc"])
        #expect(watched.code == ExitCodes.usage)
        #expect(watched.err == "Invalid session watch cursor\n")
        #expect(watched.out.isEmpty)
    }

    // MARK: The owner

    /// acpx's `continueWatching`, with acpxd in place of the session's queue owner.
    @Test func theOwnerIsLookedAtAsAcpxLooksAtItsOwn() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            var record = SessionRecord(
                acpxRecordId: "watched", acpSessionId: "watched", agentCommand: "a", cwd: "/tmp", createdAt: now,
                lastUsedAt: now)
            try SessionStore.writeRecord(record)
            let owner = WatchOwner(recordId: "watched")

            // Held, or a daemon that runs without answering: on.
            #expect(try await owner.decide(.held(pid: 1), pendingRequestId: "r"))
            #expect(try await owner.decide(.unreachable, pendingRequestId: nil))
            // Nothing holds it and a turn is in flight: one more look, then its outcome is unknown.
            #expect(try await owner.decide(.notHeld, pendingRequestId: "r"))
            await #expect(throws: SessionJournalError(code: "WATCH_OUTCOME_UNKNOWN", message: Self.outcomeUnknown)) {
                try await owner.decide(.notHeld, pendingRequestId: "r")
            }
            // Held in between, the look starts over.
            #expect(try await owner.decide(.notHeld, pendingRequestId: "s"))
            #expect(try await owner.decide(.held(pid: nil), pendingRequestId: "s"))
            #expect(try await owner.decide(.notHeld, pendingRequestId: "s"))
            // No turn in flight: on while the session is open.
            #expect(try await owner.decide(.notHeld, pendingRequestId: nil))
            record.closed = true
            try SessionStore.writeRecord(record)
            #expect(try await !owner.decide(.notHeld, pendingRequestId: nil))
            // A daemon from before it could say is one from before the journal.
            await #expect(throws: SessionJournalError.self) {
                try await owner.decide(.unknown, pendingRequestId: nil)
            }
            await #expect(throws: NoSessionError.self) {
                try await WatchOwner(recordId: "gone").decide(.notHeld, pendingRequestId: nil)
            }
        }
    }

    private static let outcomeUnknown = "Session owner ended without a settled result for request r; its outcome is "
        + "unknown. Resume watching from the last cursor after recovery, and do not automatically replay the prompt."

    // MARK: Reads, suppressed

    private let suppressed = "[read output suppressed]"

    /// With no direction, a request and its answer pair by id; over part of a history, an
    /// answer whose request came before it may be a read's, and so may a tool nothing
    /// classified.
    @Test func aHistoryReadBackHasItsReadsSuppressed() throws {
        var sanitizer = JSONMessageSanitizer(suppressReads: true, partialHistory: true)
        func sanitized(_ text: String) throws -> WireJSON {
            sanitizer.sanitize(try WireJSON.parse(text), direction: nil)
        }
        _ = try sanitized(#"{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{}}"#)
        #expect(try sanitized(#"{"jsonrpc":"2.0","id":7,"result":{"content":"secret"}}"#)["result"]?["content"]
            == .text(suppressed))
        _ = try sanitized(#"{"jsonrpc":"2.0","id":8,"method":"fs/write_text_file","params":{}}"#)
        #expect(try sanitized(#"{"jsonrpc":"2.0","id":8,"result":{"content":"kept"}}"#)["result"]?["content"]
            == .text("kept"))
        #expect(try sanitized(#"{"jsonrpc":"2.0","id":9,"result":{"content":"earlier"}}"#)["result"]?["content"]
            == .text(suppressed))

        let unclassified = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call_update","toolCallId":"t1","rawOutput":"secret"}}}"#
        #expect(try sanitized(unclassified)["params"]?["update"]?["rawOutput"]?["content"] == .text(suppressed))
        let edit = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + #"{"sessionUpdate":"tool_call","toolCallId":"t2","kind":"edit","title":"Edit","rawOutput":"kept"}}}"#
        #expect(try sanitized(edit)["params"]?["update"]?["rawOutput"] == .text("kept"))

        // A live exchange is not part of a history: an answer with no request is left alone.
        var live = JSONMessageSanitizer(suppressReads: true)
        let answer = try WireJSON.parse(#"{"jsonrpc":"2.0","id":9,"result":{"content":"earlier"}}"#)
        #expect(live.sanitize(answer, direction: .inbound)["result"]?["content"] == .text("earlier"))
    }
}
