@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import Logging
import SwiftACP
import SwiftMCP
import Testing

/// What acpxd tells the calling client about a turn that fails, and what it keeps of it
/// (#84, #57): what the agent said, then its error response, then a
/// ``TurnFailedEvent`` for the CLI to report — and the prompt stays in the session's
/// history, as acpx keeps it.
extension DaemonToolsTests {
    /// The calling client's end of the daemon's MCP session: every log notification's
    /// `data`, in the order the daemon sent them.
    final class CallingClient: Transport, @unchecked Sendable {
        let logger = Logger(label: "acpx.tests.calling-client")
        private let lock = NSLock()
        private var sent: [Data] = []

        func start() async throws {}
        func run() async throws {}
        func stop() async throws {}
        func send(_ data: Data) async throws {
            lock.withLock { sent.append(data) }
        }

        var logs: [JSONValue] {
            lock.withLock { sent }.compactMap { data -> JSONValue? in
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .object(let fields) = message, fields["method"] == .string("notifications/message"),
                      case .object(let params)? = fields["params"]
                else { return nil }
                return params["data"]
            }
        }

        /// What each log is: `update:<text>` for a reply chunk, `wire:<direction>` for
        /// a wire message, `failed` for the report — anything else by its first key.
        var kinds: [String] {
            logs.map { log in
                if let failed = try? log.decoded(TurnFailedEvent.self) { return "failed:\(failed.outputCode)" }
                if let wire = try? log.decoded(WireMessageEvent.self) {
                    let line = WireJSON(parsing: Data(wire.wireLine.utf8))
                    let what = line?["method"]?.stringValue ?? (line?.hasMember("error") == true ? "error" : "result")
                    return "wire:\(wire.wireDirection):\(what)"
                }
                if let note = try? log.decoded(SessionNotification.self),
                   case .agentMessageChunk(let block) = note.update {
                    return "update:\(block.text ?? "")"
                }
                return "other"
            }
        }

        /// ``kinds`` without the updates: what JSON output prints of a turn, and the report.
        var wireKinds: [String] {
            kinds.filter { $0.hasPrefix("wire:") || $0.hasPrefix("failed:") }
        }

        var failure: TurnFailedEvent? {
            logs.lazy.compactMap { try? $0.decoded(TurnFailedEvent.self) }.first
        }
    }

    /// What the first turn after `newSession` shows of connecting: `newSession` lets its
    /// agent go, and the mock no longer has the session, so the turn starts a new one
    /// (the failed `session/load` is left out, as acpx leaves it out).
    private static let connecting = [
        "wire:outbound:initialize", "wire:inbound:result", "wire:outbound:session/new", "wire:inbound:result"
    ]

    /// Run one turn as a calling client's request, which the daemon answers on `client`.
    func prompt(
        _ daemon: ACPXDaemonBackend, _ sessionId: String, text: String, blocks: [PromptBlock]? = nil,
        streamWire: Bool = false, client: CallingClient
    ) async throws {
        let session = Session(id: UUID())
        await session.setTransport(client)
        _ = try await session.work { _ in
            try await daemon.runPrompt(sessionId: sessionId, text: text, blocks: blocks, streamWire: streamWire)
        }
    }

    private func userTexts(_ sessionId: String) throws -> [[String]] {
        let record = try #require(SessionStore.loadRecord(sessionId))
        return record.messages.compactMap { message in
            guard case .user(let user) = message else { return nil }
            return user.content.map { content in
                switch content {
                case .text(let text): return text
                case .image: return "<image>"
                default: return "<other>"
                }
            }
        }
    }

    private func agentTexts(_ sessionId: String) throws -> [String] {
        let record = try #require(SessionStore.loadRecord(sessionId))
        return record.messages.compactMap { message in
            guard case .agent(let agent) = message else { return nil }
            return agent.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        }
    }

    /// The agent streams part of a reply, then fails the prompt. The reply reaches the
    /// client first, then the error response (which text output shows), then the report
    /// — which says the output shows it, so the CLI adds nothing but in quiet mode.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnTheAgentFailsIsReportedAfterWhatItSaid() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            await #expect(throws: JSONRPCErrorBody.self) {
                try await prompt(daemon, id, text: "fail turn", client: client)
            }
            #expect(client.kinds == Self.connecting + ["update:partial ", "wire:inbound:error", "failed:RUNTIME"])
            let failure = try #require(client.failure)
            #expect(failure.detailCode == "QUEUE_RUNTIME_PROMPT_FAILED")
            #expect(failure.shown)
            #expect(failure.sessionId == id)
            #expect(failure.acp.flatMap(AcpErrorPayload.init)?.details == "model overloaded")
            // acpx keeps the prompt, and what the agent said of it.
            #expect(try userTexts(id) == [["fail turn"]])
            #expect(try agentTexts(id) == ["partial "])
        }
    }

    /// A session with history whose `session/load` fails, without a fallback: what
    /// connecting put on the wire goes first, ending with the agent's error response,
    /// then the report. The prompt is kept although it never reached the agent (#57).
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnWhoseSessionCannotLoadKeepsItsPrompt() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let failingLoad = "/usr/bin/env MOCK_LOAD_SESSION=internal \(command)"
            let first = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await first.newSession(agentCommand: failingLoad, cwd: NSTemporaryDirectory())
            _ = try await first.runPrompt(sessionId: id, text: "hello")
            await first.evict(id)

            let client = CallingClient()
            await #expect(throws: JSONRPCErrorBody.self) {
                try await prompt(ACPXDaemonBackend(inheritAgentStderr: false), id, text: "again", client: client)
            }
            #expect(client.kinds == [
                "wire:outbound:initialize", "wire:inbound:result", "wire:outbound:session/load",
                "wire:inbound:error", "failed:RUNTIME"
            ])
            let failure = try #require(client.failure)
            #expect(failure.message == "Internal error")
            #expect(failure.shown)
            #expect(try userTexts(id) == [["hello"], ["again"]])
        }
    }

    /// A mode the agent refuses to restore while connecting is on the wire, but it is
    /// not how the turn fails: the attempt starts afresh once connected, as acpx's does,
    /// so content refused before the prompt goes out is reported as it is — not as the
    /// refused restore, which text output would then leave unreported.
    @Test(.enabled(if: mockPythonAvailable))
    func aRestoreRefusedWhileConnectingIsNotHowTheTurnFails() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: "/usr/bin/env MOCK_SET_MODE_ERROR=1 \(command)", cwd: NSTemporaryDirectory())
            var record = try #require(SessionStore.loadRecord(id))
            var acpx = record.acpx ?? SessionAcpxState()
            acpx.desiredModeId = "plan"
            record.acpx = acpx
            try SessionStore.writeRecord(record)

            let client = CallingClient()
            await #expect(throws: UnsupportedPromptContentError.self) {
                let image = PromptBlock(type: "image", data: "iVBORw0KGgo=", mimeType: "image/png")
                try await prompt(daemon, id, text: "look", blocks: [image], client: client)
            }
            #expect(client.kinds.contains("wire:inbound:error"))
            let failure = try #require(client.failure)
            #expect(failure.outputCode == "USAGE")
            #expect(!failure.shown)
            #expect(failure.acp == nil)
        }
    }

    /// A held session the agent dropped is taken back on a fresh launch, and the turn
    /// succeeds: the dropped session's error is no failure of the turn, so it is not
    /// shown, and nothing reports one.
    @Test(.enabled(if: mockPythonAvailable))
    func aDroppedSessionTakenBackShowsNoError() async throws {
        for streamWire in [false, true] {
            try await withLoggedMock(loadMode: "ok", forgetAfterPrompts: 1) { command, _ in
                let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
                let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
                _ = try await daemon.runPrompt(sessionId: id, text: "first")
                let client = CallingClient()
                try await prompt(daemon, id, text: "second", streamWire: streamWire, client: client)
                #expect(!client.kinds.contains("wire:inbound:error"), "streamWire: \(streamWire)")
                #expect(client.failure == nil)
                #expect(client.kinds.contains { $0.hasPrefix("update:") })
                // The JSON stream has the turn that succeeded, through to its result, and
                // nothing of the attempt the fresh launch took over.
                if streamWire {
                    #expect(client.wireKinds.last == "wire:inbound:result")
                    #expect(client.wireKinds.filter { $0 == "wire:outbound:session/prompt" }.count == 1)
                }
            }
        }
    }

    /// A session the agent reports gone after it answered the turn is not taken back
    /// on a fresh launch: the turn reached it, and is never sent twice. It fails, as
    /// acpx's does.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnTheAgentAnsweredIsNotRetried() async throws {
        try await withLoggedMockRequests(loadMode: "ok") { command, requests in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let client = CallingClient()
            await #expect(throws: JSONRPCErrorBody.self) {
                try await prompt(daemon, id, text: "gone turn", client: client)
            }
            #expect(client.failure?.outputCode == "NO_SESSION")
            #expect(client.failure?.shown == true)
            let prompts = try requests().filter { $0["method"] as? String == "session/prompt" }
            #expect(prompts.count == 2)
        }
    }

    /// A failure no retry follows streams its error response in JSON output as it
    /// crosses the wire, before the report.
    @Test(.enabled(if: mockPythonAvailable))
    func aJSONStreamShowsAFailureNoRetryFollows() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            await #expect(throws: JSONRPCErrorBody.self) {
                try await prompt(daemon, id, text: "fail turn", streamWire: true, client: client)
            }
            #expect(Array(client.wireKinds.suffix(2)) == ["wire:inbound:error", "failed:RUNTIME"])
        }
    }

    /// When the fresh launch that takes a dropped session back cannot even connect,
    /// the turn fails on that, not on the dropped session's error, which no output
    /// showed: the report says the output shows nothing, and names no ACP error.
    @Test(.enabled(if: mockPythonAvailable))
    func aFreshLaunchThatCannotConnectFailsOnItsOwnError() async throws {
        try await withLoggedMock(loadMode: "ok", forgetAfterPrompts: 1) { command, _ in
            // The third launch exits at once: `newSession`'s, the first turn's, and then
            // the retry's.
            let launches = ACPXPaths.baseDir.appendingPathComponent("launches")
            let wrapper = ACPXPaths.baseDir.appendingPathComponent("launch-twice.sh")
            try """
                #!/bin/sh
                n=$(cat '\(launches.path)' 2>/dev/null || echo 0)
                n=$((n + 1)); echo "$n" > '\(launches.path)'
                [ "$n" -ge 3 ] && exit 3
                exec "$@"
                """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: "'\(wrapper.path)' \(command)", cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let client = CallingClient()
            await #expect(throws: (any Error).self) {
                try await prompt(daemon, id, text: "second", client: client)
            }
            let failure = try #require(client.failure)
            #expect(!failure.shown)
            #expect(failure.acp == nil)
            #expect(!failure.message.contains("Resource not found"))
        }
    }

    /// An image for an agent that never advertised images fails the turn as a usage
    /// error, after the prompt is recorded — acpx records it before connecting.
    @Test(.enabled(if: mockPythonAvailable))
    func contentTheAgentCannotTakeFailsTheTurnAfterRecordingIt() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = CallingClient()
            await #expect(throws: UnsupportedPromptContentError.self) {
                let image = PromptBlock(type: "image", data: "iVBORw0KGgo=", mimeType: "image/png")
                try await prompt(daemon, id, text: "look", blocks: [image], client: client)
            }
            #expect(client.kinds == Self.connecting + ["failed:USAGE"])
            let failure = try #require(client.failure)
            #expect(failure.detailCode == "UNSUPPORTED_PROMPT_CONTENT")
            #expect(failure.origin == "acp")
            #expect(!failure.shown)
            #expect(failure.message == "prompt[1] image content requires agentCapabilities.promptCapabilities.image")
            #expect(try userTexts(id) == [["look", "<image>"]])
        }
    }
}
