@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// An ACP node's persistent session, as acpx 0.19.3's runner has one (#202, step 3b): made
/// by the run's first node that needs it, bound once, and each turn's messages and record
/// published in the bundle — here with scripted sessions (``ScriptedSessions``) in place of
/// acpxd. `FlowAcpPersistentRunTests` has the CLI with acpxd and a real agent.
struct FlowAcpPersistentTests {
    typealias Run = FlowRunnerHarness.Run

    /// Two nodes on the one session, then a third on a handle of its own.
    static let flow = """
        export default defineFlow({ name: "keep", startAt: "a", nodes: {
          a: acp({ prompt: () => "one" }),
          b: acp({ prompt: () => "two" }),
          c: acp({ session: { handle: "side" }, prompt: () => "three" }) },
          edges: [{ from: "a", to: "b" }, { from: "b", to: "c" }] });
        """

    private func runFlow(_ sessions: ScriptedSessions, body: String = flow) async throws -> Run {
        try await withIsolatedStore { try await FlowRunnerHarness.run(body, sessions: sessions) }
    }

    private func lines(_ text: String?) -> [WireJSON] {
        (text ?? "").split(separator: "\n").compactMap { try? WireJSON.parse(String($0)) }
    }

    private func file(_ run: Run, suffix: String, in bundleId: String) throws -> String {
        try #require(run.files["sessions/\(bundleId)/\(suffix)"], "no \(suffix) for \(bundleId)")
    }

    /// Each handle's session is made once, named for the flow, the handle, where it works
    /// and the run, and bound once; its record in the bundle is the store's as its last
    /// turn left it, and each turn's conversation starts where the turn's messages do.
    @Test func eachHandlesSessionIsMadeOnceAndBound() async throws {
        let sessions = ScriptedSessions()
        let run = try await runFlow(sessions)
        #expect(run.err.isEmpty, "\(run.err)")
        let runId = try #require(run.state?["runId"]?.stringValue)
        let hash = FlowRuntimeSupport.stableShortHash(run.flowDir)
        #expect(sessions.made == [
            .init(name: "keep-main-\(hash)-\(runId.suffix(8))", cwd: run.flowDir, recordId: "rec-1"),
            .init(name: "keep-side-\(hash)-\(runId.suffix(8))", cwd: run.flowDir, recordId: "rec-2")
        ])
        let key = WireJSON.array([.text("mock-agent"), .null, .text(run.flowDir), .text("main")]).stringified
        let main = FlowRuntimeSupport.createSessionBundleId(handle: "main", key: key)
        let binding = try WireJSON.parse(try file(run, suffix: "binding.json", in: main))
        #expect(binding["key"]?.stringValue == key)
        #expect(binding["acpxRecordId"]?.stringValue == "rec-1")
        let bound = run.trace.filter { $0["type"]?.stringValue == "session_bound" }
        #expect(bound.count == 2)
        #expect(bound.first?["sessionId"]?.stringValue == main)
        let record = try WireJSON.parse(try file(run, suffix: "record.json", in: main))
        guard case .array(let messages)? = record["messages"] else { throw FlowRunError("no messages") }
        #expect(messages.count == 4)
        #expect(record["lastSeq"] == .number(6))
        let parsed = run.trace.filter { $0["type"]?.stringValue == "acp_response_parsed" }
        #expect(parsed.map { $0["payload"]?["conversation"]?["messageStart"] } == [.number(0), .number(2), .number(0)])
        #expect(parsed.map { $0["payload"]?["conversation"]?["eventStartSeq"] } == [.number(1), .number(4), .number(1)])
        #expect(lines(run.files["sessions/\(main)/events.ndjson"]).count == 6)
    }

    /// A session whose first turn never came is let go when the run ends: here its record
    /// cannot be read, which fails its node before the turn, as acpx fails it.
    @Test func aSessionWhoseFirstTurnNeverCameIsLetGoWhenTheRunEnds() async throws {
        let sessions = ScriptedSessions()
        sessions.writesRecords = false
        let run = try await runFlow(sessions)
        #expect(run.err == "Session not found: rec-1")
        #expect(sessions.released == ["rec-1"])
    }

    /// A session made by an attempt that stopped as it was made is let go at once, and the
    /// step times out.
    @Test func aSessionMadeAsItsAttemptStoppedIsLetGo() async throws {
        let sessions = ScriptedSessions()
        sessions.timeOutWhenMade = 50
        let run = try await runFlow(sessions)
        #expect(run.err == "Timed out after 50ms")
        #expect(sessions.released == ["rec-1"])
    }

    /// A turn that fails is published as it went — its messages and its record — before
    /// the step fails with it.
    @Test func aFailedPersistentTurnIsPublished() async throws {
        let sessions = ScriptedSessions()
        sessions.failingTurn = 2
        let run = try await runFlow(sessions)
        #expect(run.err == "turn 2 failed")
        let key = WireJSON.array([.text("mock-agent"), .null, .text(run.flowDir), .text("main")]).stringified
        let main = FlowRuntimeSupport.createSessionBundleId(handle: "main", key: key)
        #expect(lines(run.files["sessions/\(main)/events.ndjson"]).count == 6)
        let record = try WireJSON.parse(try file(run, suffix: "record.json", in: main))
        guard case .array(let messages)? = record["messages"] else { throw FlowRunError("no messages") }
        #expect(messages.count == 4)
        #expect(sessions.released.isEmpty)
    }
}
