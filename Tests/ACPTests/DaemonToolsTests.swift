@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// Drives the ``ACPXDaemon`` actor directly (no MCP transport) against the
/// bundled `mock-agent.py` and an isolated session store, locking down the tool
/// wiring the daemon exposes: prompt turns return aggregate text, `newSession`
/// persists a faithful record, and the read tools surface the store.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct DaemonToolsTests {
    /// `agentCommand` for the mock: an unknown name with no override is treated as
    /// a literal command line by `AgentRegistry`, so a bare `python3 <script>`
    /// launches the fixture.
    private func mockCommand() -> String? {
        guard let python = AgentRegistry.which("python3") else { return nil }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-agent.py")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return nil }
        return "'\(python)' '\(fixture.path)'"
    }

    /// Run `body` with ``ACPXPaths/baseDir`` pointed at a fresh temp directory, so
    /// persistence never touches the real `~/.acpx`. Restores it afterwards.
    private func withIsolatedStore<T>(_ body: () async throws -> T) async rethrows -> T {
        let original = ACPXPaths.baseDir
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acpx-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ACPXPaths.baseDir = dir
        defer {
            ACPXPaths.baseDir = original
            try? FileManager.default.removeItem(at: dir)
        }
        return try await body()
    }

    @Test(.enabled(if: mockPythonAvailable))
    func newSessionThenRunPromptReturnsAggregateText() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)

            let sessionId = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory())
            #expect(sessionId == "mock-session-1")

            // The tool result is the agent's text, not a status token. Agent + cwd
            // come from the persisted record — the caller passes only the id + text.
            let reply = try await daemon.runPrompt(sessionId: sessionId, text: "ping")
            #expect(reply.contains("Hello from the mock agent! You said: ping"))
            #expect(!reply.contains("end_turn"))

            // The held session is reused for a second turn.
            let again = try await daemon.runPrompt(sessionId: sessionId, text: "again")
            #expect(again.contains("again"))
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func runPromptPersistsTurnToHistory() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())

            // Before any prompt, history is empty and the record has no lastPrompt.
            #expect(try await daemon.sessionHistory(sessionId: id).isEmpty)

            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            // The turn is now persisted: a user entry and an assistant entry.
            let history = try await daemon.sessionHistory(sessionId: id)
            #expect(history.count == 2)
            #expect(history.first?.role == "user")
            #expect(history.first?.textPreview == "ping")
            #expect(history.last?.role == "assistant")
            #expect(
                history.last?.textPreview.contains("Hello from the mock agent! You said: ping")
                    == true)

            // Activity timestamp is set (was nil before — the original bug).
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.lastPromptAt != nil)

            // The agent message captured the tool call as a ToolUse block AND a
            // tool_results entry, matching acpx's conversation model.
            let agent = record.messages.compactMap { message -> SessionAgentMessage? in
                if case .agent(let agent) = message { return agent }
                return nil
            }.first
            #expect(agent?.toolResults["call-1"]?.toolName == "echo")
            #expect(
                agent?.content.contains {
                    if case .toolUse(let tool) = $0 { return tool.id == "call-1" }
                    return false
                } == true)

            // The token breakdown from the prompt response is captured into
            // cumulative_token_usage — data upstream acpx drops.
            #expect(record.cumulativeTokenUsage?.inputTokens == 12)
            #expect(record.cumulativeTokenUsage?.outputTokens == 34)
            #expect(record.cumulativeTokenUsage?.cacheReadInputTokens == 5)
            #expect(record.cumulativeTokenUsage?.cacheCreationInputTokens == 6)
            #expect(record.cumulativeTokenUsage?.totalTokens == 57)
            #expect(record.requestTokenUsage?.values.first?.inputTokens == 12)

            // Cost comes from the usage_update (like acpx) and is captured too.
            #expect(record.cumulativeCost?.amount == 0.0042)
            #expect(record.cumulativeCost?.currency == "USD")
        }
    }

    @Test
    func recordResponseUsageMapsBreakdownToCumulativeUsage() {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: "r1", acpSessionId: "r1", agentCommand: "claude", cwd: "/tmp",
            createdAt: now, lastUsedAt: now)
        ConversationModel.recordPromptSubmission(into: &record, prompt: "hi")

        // Codex/cursor shape — note thoughtTokens (reasoning) and no cachedWrite.
        ConversationModel.recordResponseUsage(
            into: &record,
            PromptUsage(
                inputTokens: 6823, outputTokens: 1281, cachedReadTokens: 61824,
                thoughtTokens: 516, totalTokens: 69928))

        // cachedRead/Write map to acpx's cache_read / cache_creation fields.
        #expect(record.cumulativeTokenUsage?.inputTokens == 6823)
        #expect(record.cumulativeTokenUsage?.cacheReadInputTokens == 61824)
        #expect(record.cumulativeTokenUsage?.cacheCreationInputTokens == nil)
        #expect(record.cumulativeTokenUsage?.thoughtTokens == 516)
        #expect(record.cumulativeTokenUsage?.totalTokens == 69928)
        #expect(record.requestTokenUsage?.values.first?.outputTokens == 1281)
    }

    @Test(.enabled(if: mockPythonAvailable))
    func runPromptWritesEventLogStream() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            // The raw JSON-RPC wire was logged to <id>.stream.ndjson.
            let streamPath = ACPXPaths.sessionStreamPath(id)
            #expect(FileManager.default.fileExists(atPath: streamPath.path))
            let lines = try String(contentsOf: streamPath, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            #expect(!lines.isEmpty)
            #expect(lines.allSatisfy { $0.contains("\"jsonrpc\"") })
            #expect(lines.contains { $0.contains("session/prompt") })
            #expect(lines.contains { $0.contains("session/update") })

            // The record's event-log metadata advanced.
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.eventLog.lastWriteAt != nil)
            #expect(record.lastSeq > 0)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func newSessionResolvesConfigAgentAlias() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let mockPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/mock-agent.py").path

        try await withIsolatedStore {
            // A config-defined agent alias pointing at the mock (~/.acpx/config.json).
            try FileManager.default.createDirectory(
                at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let config = #"{"agents":{"mockalias":{"command":"\#(python)","args":["\#(mockPath)"]}}}"#
            try config.write(to: ACPXPaths.globalConfigPath, atomically: true, encoding: .utf8)

            let daemon = ACPXDaemon(inheritAgentStderr: false)
            // The alias resolves + launches the mock, exactly like the CLI.
            let id = try await daemon.newSession(
                agentCommand: "mockalias", cwd: NSTemporaryDirectory())
            #expect(id == "mock-session-1")

            // The record stored the RESOLVED command, not the bare alias.
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.agentCommand != "mockalias")
            #expect(record.agentCommand.contains("mock-agent.py"))
        }
    }

    @Test
    func usageUpdateCapturesCostAndBreakdown() {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: "u1", acpSessionId: "u1", agentCommand: "claude", cwd: "/tmp",
            createdAt: now, lastUsedAt: now)
        ConversationModel.recordPromptSubmission(into: &record, prompt: "hi")

        // Full Claude-Code-style usage_update: cost + _meta.usage breakdown.
        let full = SessionUpdate.usageUpdate(
            UsageUpdate(
                used: 1200, size: 200_000,
                cost: .init(amount: 0.0123, currency: "USD"),
                meta: .object([
                    "usage": .object([
                        "inputTokens": .integer(800), "outputTokens": .integer(400),
                        "totalTokens": .integer(1925)
                    ])
                ])))
        ConversationModel.recordSessionUpdate(
            into: &record, notification: SessionNotification(sessionId: "u1", update: full))
        #expect(record.cumulativeCost?.amount == 0.0123)
        #expect(record.cumulativeCost?.currency == "USD")
        #expect(record.cumulativeTokenUsage?.inputTokens == 800)
        #expect(record.cumulativeTokenUsage?.totalTokens == 1925)
        #expect(record.requestTokenUsage?.values.first?.outputTokens == 400)

        // Bare Codex-style usage_update (only used/size): no breakdown captured —
        // cumulative_token_usage stays empty, exactly as upstream acpx leaves it.
        var codex = SessionRecord(
            acpxRecordId: "u2", acpSessionId: "u2", agentCommand: "codex", cwd: "/tmp",
            createdAt: now, lastUsedAt: now)
        let bare = SessionUpdate.usageUpdate(UsageUpdate(used: 50, size: 1000))
        ConversationModel.recordSessionUpdate(
            into: &codex, notification: SessionNotification(sessionId: "u2", update: bare))
        #expect(codex.cumulativeTokenUsage == nil)
        #expect(codex.cumulativeCost == nil)
    }

    @Test
    func turnPersisterCheckpointsDuringTheRun() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            var seed = SessionRecord(
                acpxRecordId: "cp-1", acpSessionId: "cp-1", agentCommand: "claude", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            seed.closed = false
            try SessionStore.writeRecord(seed)

            let persister = TurnPersister(record: seed, intervalNanos: 20_000_000)
            await persister.recordPrompt("hello")
            // Poll for the 20ms debounced checkpoint (a flat sleep flakes on a stalled runner):
            // the user message lands on disk before finish(), so mid-run reads see partial history.
            var midRun: SessionRecord?
            for _ in 0 ..< 200 where midRun == nil {
                midRun = SessionStore.loadRecord("cp-1").flatMap { $0.messages.count == 1 ? $0 : nil }
                if midRun == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            // Checkpointed mid-run: message written, but not finish()'s timestamps yet.
            #expect(try #require(midRun, "live checkpoint did not land").lastPromptAt == nil)

            await persister.finish()
            let final = try #require(SessionStore.loadRecord("cp-1"))
            #expect(final.lastPromptAt != nil)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func newSessionPersistsRecordReadableByReadTools() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory(), name: "demo")

            // A real record landed on disk (the same one the CLI's `sessions new` writes).
            let onDisk = try #require(SessionStore.loadRecord(id))
            #expect(onDisk.name == "demo")
            #expect(onDisk.lastAgentDisconnectReason == "connection_close")

            // listSessions surfaces it.
            let listed = await daemon.listSessions()
            #expect(listed.contains { $0.id == id && $0.name == "demo" })

            // showSession returns matching detail (by record id and by ACP session id).
            let detail = try await daemon.showSession(sessionId: id)
            #expect(detail.id == id)
            #expect(detail.agentCommand == command)
            let byAcp = try await daemon.showSession(sessionId: onDisk.acpSessionId)
            #expect(byAcp.id == id)
        }
    }

    @Test
    func sessionHistoryRespectsLimit() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            var record = SessionRecord(
                acpxRecordId: "hist-1", acpSessionId: "acp-1", agentCommand: "claude",
                cwd: "/tmp", name: nil, createdAt: now, lastUsedAt: now)
            record.messages = [
                .user(SessionUserMessage(id: "u1", content: [.text("first question")])),
                .agent(SessionAgentMessage(content: [.text("first answer")])),
                .user(SessionUserMessage(id: "u2", content: [.text("second question")]))
            ]
            try SessionStore.writeRecord(record)

            let daemon = ACPXDaemon(inheritAgentStderr: false)

            let all = try await daemon.sessionHistory(sessionId: "hist-1")
            #expect(all.count == 3)
            #expect(all.first?.role == "user")
            #expect(all[1].role == "assistant")
            #expect(all.first?.textPreview == "first question")

            // limit keeps the last N (suffix), like `sessions history --limit`.
            let lastTwo = try await daemon.sessionHistory(sessionId: "hist-1", limit: 2)
            #expect(lastTwo.count == 2)
            #expect(lastTwo.first?.textPreview == "first answer")
            #expect(lastTwo.last?.textPreview == "second question")
        }
    }

    @Test
    func showSessionThrowsForUnknownId() async {
        await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            await #expect(throws: DaemonError.self) {
                _ = try await daemon.showSession(sessionId: "does-not-exist")
            }
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func setModePersistsDesiredMode() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let ok = try await daemon.setMode(sessionId: id, modeId: "auto")
            #expect(ok)
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpx?.desiredModeId == "auto")
            #expect(record.acpx?.currentModeId == "auto")
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func setConfigOptionPersistsDesiredOption() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let ok = try await daemon.setConfigOption(sessionId: id, configId: "model", value: "opus")
            #expect(ok)
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpx?.desiredConfigOptions?["model"] == "opus")
        }
    }

    @Test
    func closeSessionMarksRecordClosed() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            var record = SessionRecord(
                acpxRecordId: "c1", acpSessionId: "c1", agentCommand: "claude", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            record.closed = false
            try SessionStore.writeRecord(record)

            let daemon = ACPXDaemon(inheritAgentStderr: false)
            let ok = try await daemon.closeSession(sessionId: "c1")
            #expect(ok)
            let updated = try #require(SessionStore.loadRecord("c1"))
            #expect(updated.closed == true)
            #expect(updated.closedAt != nil)

            // Unknown id returns false rather than throwing.
            let missing = try await daemon.closeSession(sessionId: "nope")
            #expect(!missing)
        }
    }

    @Test
    func pruneSessionsDeletesOnlyClosed() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            var open = SessionRecord(
                acpxRecordId: "open", acpSessionId: "open", agentCommand: "claude", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            open.closed = false
            var closed = SessionRecord(
                acpxRecordId: "closed", acpSessionId: "closed", agentCommand: "claude", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            closed.closed = true
            closed.closedAt = now
            try SessionStore.writeRecord(open)
            try SessionStore.writeRecord(closed)

            let daemon = ACPXDaemon(inheritAgentStderr: false)

            // Dry run reports the closed one but deletes nothing.
            let dry = await daemon.pruneSessions(dryRun: true)
            #expect(dry.count == 1)
            #expect(dry.pruned == ["closed"])
            #expect(SessionStore.loadRecord("closed") != nil)

            // Real prune removes only the closed record.
            let result = await daemon.pruneSessions()
            #expect(result.count == 1)
            #expect(SessionStore.loadRecord("closed") == nil)
            #expect(SessionStore.loadRecord("open") != nil)
        }
    }

    @Test
    func pruneSessionsHonorsOlderThanCutoff() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            var closed = SessionRecord(
                acpxRecordId: "recent", acpSessionId: "recent", agentCommand: "claude", cwd: "/tmp",
                createdAt: now, lastUsedAt: now)
            closed.closed = true
            closed.closedAt = now
            try SessionStore.writeRecord(closed)

            let daemon = ACPXDaemon(inheritAgentStderr: false)
            // Closed just now → not older than a day → kept.
            let result = await daemon.pruneSessions(olderThanDays: 1)
            #expect(result.count == 0)
            #expect(SessionStore.loadRecord("recent") != nil)
        }
    }

    @Test
    func listSessionsAgentFilterMatchesNameOrExpandedCommandAndIgnoresBlank() async throws {
        try await withIsolatedStore {
            let now = nowISO()
            func seed(_ id: String, agent: String) throws {
                var record = SessionRecord(
                    acpxRecordId: id, acpSessionId: id, agentCommand: agent, cwd: "/tmp",
                    createdAt: now, lastUsedAt: now)
                record.closed = false
                try SessionStore.writeRecord(record)
            }
            let claudeCommand = try #require(AgentRegistry.command(for: "claude"))
            try seed("by-name", agent: "claude")
            try seed("by-command", agent: claudeCommand)
            try seed("a-codex", agent: "codex")

            let daemon = ACPXDaemon(inheritAgentStderr: false)

            // "claude" matches both the short-name and expanded-command sessions.
            let byName = await daemon.listSessions(agentCommand: "claude")
            #expect(byName.map(\.id).sorted() == ["by-command", "by-name"])

            // Filtering by the expanded command finds the same two.
            let byCommand = await daemon.listSessions(agentCommand: claudeCommand)
            #expect(byCommand.map(\.id).sorted() == ["by-command", "by-name"])

            // Blank / whitespace-only is treated as no filter → all sessions.
            #expect(await daemon.listSessions(agentCommand: "   ").count == 3)
            #expect(await daemon.listSessions(agentCommand: nil).count == 3)
        }
    }

    @Test
    func toolMetadataCarriesAnnotationsAndParameterDescriptions() async {
        let tools = await ACPXDaemon(inheritAgentStderr: false).mcpToolMetadata
        func tool(_ name: String) -> MCPToolMetadata? { tools.first { $0.name == name } }

        // Read tools advertise read-only + idempotent. (SwiftMCP hints are
        // presence-only: a hint is `true` or absent/`nil` — never explicit false.)
        #expect(tool("listSessions")?.annotations?.readOnlyHint == true)
        #expect(tool("listSessions")?.annotations?.idempotentHint == true)
        #expect(tool("listSessions")?.annotations?.destructiveHint == nil)
        #expect(tool("sessionHistory")?.annotations?.readOnlyHint == true)

        // prune is the destructive one; runPrompt is not read-only but is open-world.
        #expect(tool("pruneSessions")?.annotations?.destructiveHint == true)
        #expect(tool("runPrompt")?.annotations?.readOnlyHint == nil)
        #expect(tool("runPrompt")?.annotations?.openWorldHint == true)

        // Parameters carry descriptions parsed from the doc comments.
        let agentParam = tool("listSessions")?.parameters.first { $0.name == "agentCommand" }
        #expect(agentParam?.description?.isEmpty == false)
        let textParam = tool("runPrompt")?.parameters.first { $0.name == "text" }
        #expect(textParam?.description?.isEmpty == false)
    }

    @Test
    func runPromptRejectsEmptySessionId() async throws {
        let daemon = ACPXDaemon(inheritAgentStderr: false)
        await #expect(throws: DaemonError.self) {
            _ = try await daemon.runPrompt(sessionId: "   ", text: "hi")
        }
    }

    @Test
    func runPromptThrowsForUnknownSession() async {
        await withIsolatedStore {
            let daemon = ACPXDaemon(inheritAgentStderr: false)
            await #expect(throws: DaemonError.self) {
                _ = try await daemon.runPrompt(sessionId: "does-not-exist", text: "hi")
            }
        }
    }
}
