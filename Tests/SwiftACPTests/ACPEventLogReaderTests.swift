#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import SwiftACP
import Testing

/// The typed reader over ``ACPEventLogWriter``'s NDJSON (#335): prompts, their answers and
/// `session/update`s in file order, other ACP messages left out, a partial tail skipped.
@Suite struct ACPEventLogReaderTests {
    private let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#
    private let prompt =
        #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s1","#
        + #""prompt":[{"type":"text","text":"Hi"}]}}"#
    private let chunk =
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"#
        + #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#
    /// The agent's own request, with the same id as the client's prompt.
    private let permission =
        #"{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"s1"}}"#
    private let permissionAnswer = #"{"jsonrpc":"2.0","id":1,"result":{"outcome":{"outcome":"cancelled"}}}"#
    private let answer = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#

    @Test func eventLogRoundTripPromptUpdatesAndResponse() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            for line in [initialize, prompt, chunk, permission, permissionAnswer, chunk, answer] {
                try writer.append(Data(line.utf8))
            }
            let entries = try ACPEventLogReader(url).entries()
            #expect(entries.count == 4)
            guard entries.count == 4 else { return }

            guard case .prompt(let promptId, let request) = entries[0] else {
                Issue.record("expected a prompt, got \(entries[0])")
                return
            }
            #expect(promptId == .integer(1))
            #expect(request.sessionId == "s1")
            for entry in entries[1...2] {
                guard case .update(let notification) = entry, case .agentMessageChunk = notification.update else {
                    Issue.record("expected an agent_message_chunk update, got \(entry)")
                    continue
                }
                #expect(notification.sessionId == "s1")
                #expect(notification.rawUpdate?["sessionUpdate"] == .text("agent_message_chunk"))
            }
            guard case .promptResponse(let answerId, let response) = entries[3] else {
                Issue.record("expected the prompt's response, got \(entries[3])")
                return
            }
            #expect(answerId == .integer(1))
            #expect(response.stopReason == .endTurn)
        }
    }

    @Test func aPromptAnsweredWithAnErrorReplaysTheError() {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#
        let entries = ACPEventLogReader.entries(in: Data((prompt + "\n" + error + "\n").utf8))
        #expect(entries.count == 2)
        guard entries.count == 2, case .promptError(let id, let body) = entries[1] else {
            Issue.record("expected the prompt's error, got \(entries)")
            return
        }
        #expect(id == .integer(1))
        #expect(body.code == -32603)
        #expect(body.message == "boom")
    }

    /// The prompt answered while the agent's same-id permission request is still open: the
    /// answer is the prompt's, and the permission's cancellation after it is not (#337).
    @Test func aPromptAnsweredBeforeTheAgentsSameIdRequestKeepsItsAnswer() {
        let entries = ACPEventLogReader.entries(in: ndjson([prompt, permission, answer, permissionAnswer]))
        #expect(entries.count == 2)
        guard entries.count == 2, case .promptResponse(let id, let response) = entries[1] else {
            Issue.record("expected the prompt's response, got \(entries)")
            return
        }
        #expect(id == .integer(1))
        #expect(response.stopReason == .endTurn)
    }

    /// An error with the id open on both sides: the prompt's when what answers the other
    /// request after it is no prompt response, the agent's request's when it is.
    @Test func anErrorOpenOnBothSidesGoesByTheAnswerAfterIt() {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"#
        let failed = ACPEventLogReader.entries(in: ndjson([prompt, permission, error, permissionAnswer]))
        #expect(failed.count == 2)
        if failed.count == 2, case .promptError = failed[1] {} else {
            Issue.record("expected the prompt's error, got \(failed)")
        }

        let readFailed = ACPEventLogReader.entries(in: ndjson([prompt, permission, error, answer]))
        #expect(readFailed.count == 2)
        if readFailed.count == 2, case .promptResponse = readFailed[1] {} else {
            Issue.record("expected the prompt's response, got \(readFailed)")
        }
    }

    /// An agent request of a method the reader does not know, with the open prompt's id,
    /// is the agent's: it neither replaces the prompt nor takes the prompt's answer.
    @Test func anUnknownRequestWithThePromptsIdIsTheAgents() {
        let vendor = #"{"jsonrpc":"2.0","id":1,"method":"_vendor/foo","params":{}}"#
        let notFound = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#
        let entries = ACPEventLogReader.entries(in: ndjson([prompt, vendor, notFound, answer]))
        #expect(entries.count == 2)
        if entries.count == 2, case .promptResponse(let id, _) = entries[1] {
            #expect(id == .integer(1))
        } else {
            Issue.record("expected the prompt's response, got \(entries)")
        }
    }

    @Test func eventLogReaderToleratesPartialLastLine() throws {
        try withTempLog { url in
            let writer = ACPEventLogWriter(url)
            try writer.append(Data(prompt.utf8))
            try writer.append(Data(chunk.utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(answer.utf8.prefix(20)))
            try handle.close()

            let entries = try ACPEventLogReader(url).entries()
            #expect(entries.count == 2)
            guard entries.count == 2, case .prompt = entries[0], case .update = entries[1] else {
                Issue.record("expected the prompt and its update, got \(entries)")
                return
            }
        }
    }

    @Test func aMissingLogThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { _ = try ACPEventLogReader(url).entries() }
    }

    private func ndjson(_ lines: [String]) -> Data {
        Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    private func withTempLog(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("events.ndjson"))
    }
}
#endif
