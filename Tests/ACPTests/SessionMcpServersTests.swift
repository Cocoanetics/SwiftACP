@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Per-session MCP servers over the daemon API (issue #17): `newSession(mcpServers:)`
/// persists the session's own server set, every reconnect replays it in place of the
/// cwd's config-file servers, and `setSessionMcpServers` follows npm acpx's rule that
/// a live session cannot switch MCP config.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct SessionMcpServersTests {
    private static let own = McpServerConfig(
        name: "shot", command: "/usr/local/bin/shot-mcp", args: ["--run", "42"],
        env: [.init(name: "RUN_TOKEN", value: "secret")], meta: ["run": .string("42")])
    private static let other = McpServerConfig(type: "http", name: "remote", url: "https://example.com/mcp")

    @Test(.enabled(if: mockPythonAvailable))
    func ownServersReplaceConfigAndReplayOnEveryReconnect() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try writeGlobalConfig(servers: #"[{"name":"cfg","command":"cfg-tool"}]"#)
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)

            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory(),
                mcpServers: [Self.own])

            // Persisted on the record's acpx block and surfaced by showSession.
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.acpx?.mcpServers == [Self.own])
            #expect(try await daemon.showSession(sessionId: id).mcpServers == [Self.own])

            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            // The create spawn, the reconnect (session/load) and its session-gone
            // fallback (session/new) all carry the session's own set, never `cfg`.
            let requests = try sessionRequests(log)
            #expect(requests.map(\.method) == ["session/new", "session/load", "session/new"])
            for request in requests {
                #expect(request.servers.count == 1)
                #expect(request.servers.first?["name"] as? String == "shot")
                #expect(request.servers.first?["args"] as? [String] == ["--run", "42"])
                #expect(request.servers.first?["type"] == nil)
                #expect((request.servers.first?["_meta"] as? [String: String])?["run"] == "42")
                #expect(
                    (request.servers.first?["env"] as? [[String: String]])
                        == [["name": "RUN_TOKEN", "value": "secret"]])
            }
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func emptyOwnListDetachesConfigServers() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try writeGlobalConfig(servers: #"[{"name":"cfg","command":"cfg-tool"}]"#)
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)

            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory(),
                mcpServers: [])
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            let requests = try sessionRequests(log)
            #expect(requests.count == 3)
            #expect(requests.flatMap(\.servers).isEmpty)
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [])
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func omittedListKeepsConfigServers() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try writeGlobalConfig(servers: #"[{"name":"cfg","command":"cfg-tool"}]"#)
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)

            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            let requests = try sessionRequests(log)
            #expect(requests.count == 3)
            #expect(requests.allSatisfy { $0.servers.map { $0["name"] as? String } == ["cfg"] })
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == nil)
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func setSessionMcpServersIsRefusedWhileLiveWithADifferentSet() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())

            // Not live yet: the set is simply persisted.
            #expect(try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.own]))
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [Self.own])

            // The reconnect uses the persisted set …
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")
            let reconnects = try sessionRequests(log).dropFirst()
            #expect(reconnects.count == 2)
            #expect(reconnects.allSatisfy { $0.servers.map { $0["name"] as? String } == ["shot"] })

            // … and while that connection is held, a different set is a conflict
            // (npm acpx's QUEUE_MCP_CONFIG_CONFLICT); the same set is a no-op.
            await #expect(throws: DaemonError.self) {
                try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.other])
            }
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [Self.own])
            #expect(try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.own]))

            // Closing the session releases the connection, after which it may switch.
            #expect(try await daemon.closeSession(sessionId: id))
            #expect(try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.other]))
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [Self.other])
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func conflictErrorNamesTheSessionAndMirrorsNpmWording() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")
            do {
                _ = try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.own])
                Issue.record("expected a conflict")
            } catch let error as DaemonError {
                guard case .mcpConfigConflict(let conflicted) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(conflicted == id)
                #expect(error.localizedDescription.contains("close the session before retrying"))
            }
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test func setSessionMcpServersValidatesEntriesBeforePersisting() async throws {
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            var record = SessionRecord(
                acpxRecordId: "rec-1", acpSessionId: "acp-1", agentCommand: "mock",
                cwd: "/tmp", createdAt: nowISO(), lastUsedAt: nowISO())
            record.closed = false
            try SessionStore.writeRecord(record)

            // A stdio entry without a command is rejected the way the config loader
            // rejects it, and nothing is written.
            await #expect(throws: ConfigError.self) {
                try await daemon.setSessionMcpServers(
                    sessionId: "rec-1", mcpServers: [McpServerConfig(name: "broken")])
            }
            #expect(try #require(SessionStore.loadRecord("rec-1")).acpx?.mcpServers == nil)

            await #expect(throws: DaemonError.self) {
                try await daemon.setSessionMcpServers(sessionId: "missing", mcpServers: [Self.own])
            }
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func equivalentSetsWrittenDifferentlyAreNotAConflict() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let terse = McpServerConfig(name: "shot", command: "/bin/shot")
            let verbose = McpServerConfig(
                type: "stdio", name: "shot", command: "/bin/shot", args: [], env: [])

            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory(), mcpServers: [terse])
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            // Both spell the same `session/new` params, so re-sending the spelled-out
            // form while live is the no-op it looks like, not a conflict (npm acpx
            // fingerprints the parsed servers, not the config text).
            #expect(try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [verbose]))
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [verbose])
            // …and the held connection still serves the next turn.
            _ = try await daemon.runPrompt(sessionId: id, text: "again")
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func configFileSessionsNeverConflictWhenTheConfigChangesWhileLive() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try writeGlobalConfig(servers: #"[{"name":"cfg","command":"cfg-tool"}]"#)
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            // Editing the config file under a live session must not start failing its
            // turns: npm only pins a session to an *explicit* MCP config, and a
            // retained connection keeps the servers it was made with.
            try writeGlobalConfig(servers: #"[{"name":"changed","command":"other-tool"}]"#)
            _ = try await daemon.runPrompt(sessionId: id, text: "again")
            #expect(try sessionRequests(log).allSatisfy { request in
                request.servers.map { $0["name"] as? String } == ["cfg"]
            })
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func ownServersSurviveABadConfigFileInTheCwd() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            // A stdio entry with no command: unusable, but irrelevant to a caller
            // bringing its own servers, so it must not fail the call.
            try writeGlobalConfig(servers: #"[{"name":"broken"}]"#)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory(), mcpServers: [Self.own])
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [Self.own])

            // Without its own set the same session creation does surface the error.
            await #expect(throws: ConfigError.self) {
                try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            }
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    /// Closing and attaching servers in flight leave a consistent record whichever
    /// way the two interleave. The close takes its turn with the session, so an attach
    /// that gets there first still finds the agent held and refuses; one that comes
    /// after it goes through. (The specific lost-update window inside `closeSession` —
    /// its write landing after another tool's — is a single actor hop and is not
    /// deterministically reproducible here; the guard is the re-read in
    /// `closeSession`, not this test.)
    @Test(.enabled(if: mockPythonAvailable))
    func closeAndAttachConcurrentlyLeaveAConsistentRecord() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            // The sequence the conflict message invites, run concurrently.
            async let closing: Bool = daemon.closeSession(sessionId: id)
            async let setting: Result<Bool, Error> = {
                do {
                    return .success(try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.own]))
                } catch {
                    return .failure(error)
                }
            }()
            let (closed, set) = try await (closing, setting)
            #expect(closed)
            let record = try #require(SessionStore.loadRecord(id))
            #expect(record.closed == true)
            switch set {
            case .success(let applied):
                #expect(applied)
                #expect(record.acpx?.mcpServers == [Self.own])
            case .failure(let error):
                guard case DaemonError.mcpConfigConflict = error else {
                    Issue.record("the attach failed otherwise: \(error)")
                    return
                }
                #expect(record.acpx?.mcpServers == nil)
            }
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func restartSwitchesALiveSessionsServersWithoutLosingIt() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLogURL()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand(command, log: log), cwd: NSTemporaryDirectory(),
                mcpServers: [Self.own])
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")
            #expect(SessionStore.loadRecord(id)?.pid != nil)

            // Without `restart` the live session refuses the switch (npm's rule) …
            await #expect(throws: DaemonError.self) {
                try await daemon.setSessionMcpServers(sessionId: id, mcpServers: [Self.other])
            }
            // … with it, the switch is applied by dropping the adapter, so the next
            // turn reconnects with the new servers. The session itself survives: it
            // is restored, not recreated, and its history is intact.
            #expect(try await daemon.setSessionMcpServers(
                sessionId: id, mcpServers: [Self.other], restart: true))
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [Self.other])
            // The adapter it dropped leaves no pid behind (#113 review).
            #expect(SessionStore.loadRecord(id)?.pid == nil)

            _ = try await daemon.runPrompt(sessionId: id, text: "after switch")
            let requests = try sessionRequests(log)
            #expect(requests.map(\.method) == [
                "session/new", "session/load", "session/new", "session/load", "session/new"
            ])
            #expect(requests.prefix(3).allSatisfy { $0.servers.map { $0["name"] as? String } == ["shot"] })
            #expect(requests.suffix(2).allSatisfy { $0.servers.map { $0["name"] as? String } == ["remote"] })
            // Both turns are in one conversation — the switch kept the session.
            #expect(try await daemon.sessionHistory(sessionId: id).count == 4)
            _ = try await daemon.closeSession(sessionId: id)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func restartOnAnIdleSessionJustPersists() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory(), mcpServers: [Self.own])
            #expect(try await daemon.setSessionMcpServers(
                sessionId: id, mcpServers: [Self.other], restart: true))
            #expect(try #require(SessionStore.loadRecord(id)).acpx?.mcpServers == [Self.other])
        }
    }

    // MARK: - Helpers

    private func writeGlobalConfig(servers: String) throws {
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        try #"{"mcpServers":\#(servers)}"#
            .write(to: ACPXPaths.globalConfigPath, atomically: true, encoding: .utf8)
    }

    private func requestLogURL() -> URL {
        ACPXPaths.baseDir.appendingPathComponent("requests-\(UUID().uuidString).ndjson")
    }

    /// The mock agent appends every `session/*` request it receives to `log`.
    private func loggedCommand(_ command: String, log: URL) -> String {
        "/usr/bin/env MOCK_REQUEST_LOG='\(log.path)' \(command)"
    }

    private struct LoggedRequest {
        var method: String
        var servers: [[String: Any]]
    }

    /// The session-setup requests (everything but `session/prompt`) with their
    /// `mcpServers` param, in the order the agent received them.
    private func sessionRequests(_ log: URL) throws -> [LoggedRequest] {
        try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            .filter { ($0["method"] as? String) != "session/prompt" }
            .map { request in
                let params = try #require(request["params"] as? [String: Any])
                return LoggedRequest(
                    method: try #require(request["method"] as? String),
                    servers: try #require(params["mcpServers"] as? [[String: Any]]))
            }
    }
}
