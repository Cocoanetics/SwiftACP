#if os(macOS) || os(Linux) || os(Windows)
@testable import ACPXCore
import Foundation
import SwiftACP
import Testing

/// A log ``ACPEventLogWriter`` writes is one `SessionArchive.history` reads whole, and
/// one ``ACPEventLogReader`` reads its prompt, update and answer from (#335).
@Suite struct ACPEventLogArchiveTests {
    private let lines = [
        #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s1","prompt":[]}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"#
            + #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#
    ]

    @Test func aWrittenEventLogIsAnArchiveHistory() async throws {
        try await withIsolatedStore {
            let id = "event-log-archive"
            let url = ACPXPaths.sessionStreamPath(id)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writer = ACPEventLogWriter(url)
            for line in lines {
                try writer.append(Data(line.utf8))
            }
            let now = nowISO()
            let record = SessionRecord(
                acpxRecordId: id, acpSessionId: id, agentCommand: "codex", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)

            let history = try SessionArchive.history(of: record)
            #expect(history == lines.map { try? WireJSON.parse($0) })
            #expect(history.allSatisfy(SessionArchive.isACPMessage))
            #expect(try ACPEventLogReader(url).entries().count == 3)
        }
    }
}
#endif
