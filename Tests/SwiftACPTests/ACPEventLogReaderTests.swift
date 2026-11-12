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

    private func withTempLog(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("events.ndjson"))
    }
}
#endif
