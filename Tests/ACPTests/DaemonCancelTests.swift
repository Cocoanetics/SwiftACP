@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

#if canImport(Glibc)
import Glibc
#endif

/// Cancelling a turn through the daemon as acpx's queue owner cancels one (#109): before
/// its prompt goes out, the prompt is never sent and the turn ends cancelled; once it is
/// out, one `session/cancel` goes to it; with no turn running there is nothing to cancel,
/// and nothing is sent.
extension DaemonToolsTests {
    /// What the tests' hooks were answered.
    actor Answers {
        private(set) var values: [Bool] = []
        func append(_ value: Bool) { values.append(value) }
    }

    /// The mock agent, taking sessions back, logging the `session/*` requests it gets to
    /// `log`, and started with `options`.
    private static func loggingMock(_ log: URL, _ options: String = "") throws -> String {
        let command = try #require(mockCommand())
        return "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_REQUEST_LOG='\(log.path)' \(options) \(command)"
    }

    /// The methods of the `session/*` requests `log` holds.
    private static func requests(_ log: URL) -> [String] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { WireJSON(parsing: Data($0.utf8))?["method"]?.stringValue }
    }

    /// How the calling client was told the turn ended.
    private static func stopReason(_ client: CallingClient) -> String? {
        client.logs.lazy.compactMap { try? $0.decoded(TurnEndedEvent.self) }.first?.stopReason
    }

    /// A fresh directory for a test's files.
    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `fifo` opened to write, which waits for its reader — on a thread of its own, not
    /// one of Swift's.
    private static func openForWriting(_ fifo: URL) async -> Int32 {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: open(fifo.path, O_WRONLY)) }.start()
        }
    }

    /// A cancel while the turn connects keeps its prompt from being sent: the turn ends
    /// cancelled once connected, with the user's message kept, as acpx 0.19.1 ends it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnCancelledWhileItConnectsSendsNoPrompt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (log, gate) = (directory.appendingPathComponent("requests.log"), directory.appendingPathComponent("gate"))
        #expect(mkfifo(gate.path, 0o600) == 0)
        let command = try Self.loggingMock(log, "MOCK_LOAD_GATE='\(gate.path)'")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            let turn = Task { try await prompt(daemon, id, text: "hi", client: client) }
            // The agent is loading the session once its gate opens to be written.
            let writer = await Self.openForWriting(gate)
            #expect(try await daemon.cancelSession(sessionId: id))
            close(writer)
            try await turn.value
            #expect(Self.stopReason(client) == "cancelled")
            #expect(Self.requests(log).contains("session/load"))
            #expect(!Self.requests(log).contains("session/prompt"))
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.messages.contains { if case .user = $0 { true } else { false } })
        }
    }

    /// A cancel that comes as the prompt is going out — however often — is sent once the
    /// prompt is out: one `session/cancel`, after the prompt.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnCancelledAsItsPromptGoesOutIsCancelledOnce() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let command = try Self.loggingMock(log, "MOCK_HOLD_UNTIL_CANCEL=1")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let answers = Answers()
            await daemon.setPromptGoingOut { recordId in
                for _ in 0..<2 { await answers.append((try? await daemon.cancelSession(sessionId: recordId)) ?? false) }
            }
            let client = CallingClient()
            try await prompt(daemon, id, text: "hi", client: client)
            #expect(await answers.values == [true, true])
            #expect(Self.stopReason(client) == "cancelled")
            let requests = Self.requests(log)
            #expect(requests.filter { $0 == "session/cancel" }.count == 1)
            #expect(requests.suffix(2) == ["session/prompt", "session/cancel"])
        }
    }

    /// With no turn running, a session has nothing to cancel — though its agent is held —
    /// and no `session/cancel` is sent.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionWithNoTurnHasNothingToCancel() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let command = try Self.loggingMock(log)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try await prompt(daemon, id, text: "hi", client: CallingClient())
            #expect(try await daemon.cancelSession(sessionId: id) == false)
            #expect(!Self.requests(log).contains("session/cancel"))
        }
    }
}

extension ACPXDaemonBackend {
    func setPromptGoingOut(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        promptGoingOut = hook
    }
}
