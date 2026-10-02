@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// `sessions new` creates the new session first and only then closes the one it replaces,
/// as acpx 0.19.3 does (#778, for our openclaw/acpx#767): a creation that fails leaves the
/// old session open. The new record has an id of its own, as acpx 0.19.4 gives it one, so the
/// close reaches the replaced record whatever id the agent gave the new session
/// (openclaw/acpx#805).
@Suite(.serialized, .agentLane) struct SessionsNewReplacementTests {
    /// The mock agent behind a wrapper whose command never changes, so every run is the
    /// same scope: a `fail` file makes it refuse `session/new`, a `same-id` file makes it
    /// give every session the same id.
    private static func agent(in directory: URL) throws -> String {
        let command = try #require(mockCommand())
        let wrapper = directory.appendingPathComponent("agent.sh")
        try """
            #!/bin/sh
            [ -f '\(directory.path)/fail' ] && export MOCK_NEW_ERROR='{"code":-32603,"message":"boom"}'
            [ -f '\(directory.path)/same-id' ] || export MOCK_SESSION_ID_PER_PROCESS=1
            exec \(command)
            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return "'\(wrapper.path)'"
    }

    /// What a `sessions new` came to.
    private struct Run {
        let code: Int32
        /// The new session's id.
        let id: String
        /// What it wrote to stderr.
        let err: String
    }

    /// `acpx --agent <agent> --cwd <directory> --format quiet sessions new`, with `daemon`
    /// the one running.
    private static func sessionsNew(
        _ agent: String, in directory: URL, daemon: MCPServerConfig? = nil
    ) async -> Run {
        let capture = Console.Capture()
        let code = await onThreadOfItsOwn {
            DaemonClient.$standIn.withValue(daemon) {
                Console.$capture.withValue(capture) {
                    runCommandLine(["--agent", agent, "--cwd", directory.path, "--format", "quiet", "sessions", "new"])
                }
            }
        }
        return Run(code: code, id: capture.out.trimmingCharacters(in: .whitespacesAndNewlines), err: capture.err)
    }

    private static func touch(_ name: String, in directory: URL) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionsNewThatFailsLeavesTheSessionItWouldReplaceOpen() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            #expect(first.code == 0)
            Self.touch("fail", in: directory)
            #expect(await Self.sessionsNew(agent, in: directory).code != 0)
            let kept = try #require(SessionStore.loadRecord(first.id))
            #expect(kept.closed != true, "the session it would have replaced is still open")
        }
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionsNewClosesTheSessionItReplacesOnceItHasOne() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let second = await Self.sessionsNew(agent, in: directory)
            #expect(first.code == 0 && second.code == 0)
            #expect(first.id != second.id)
            #expect(try #require(SessionStore.loadRecord(first.id)).closed == true)
            #expect(try #require(SessionStore.loadRecord(second.id)).closed != true)
        }
    }

    /// An agent that gives every session the same id: the new session gets a record of its
    /// own all the same, the replaced one is closed, and the new one stays open — acpx
    /// 0.19.4's `sessions new leaves the replacement open when the adapter repeats its ID`
    /// (openclaw/acpx#805).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aNewSessionUnderTheReplacedIdGetsARecordOfItsOwn() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            Self.touch("same-id", in: directory)
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let second = await Self.sessionsNew(agent, in: directory)
            #expect(first.code == 0 && second.code == 0)
            #expect(first.id != second.id)
            let prior = try #require(SessionStore.loadRecord(first.id))
            let current = try #require(SessionStore.loadRecord(second.id))
            #expect(prior.acpSessionId == "mock-session-1" && current.acpSessionId == "mock-session-1")
            #expect(prior.closed == true)
            #expect(current.closed != true)
        }
    }

    /// A daemon holding the replaced session closes it when the new session takes the same
    /// id: its agent goes, its record is closed with the conversation it had, and the new
    /// session's record is open, with none of it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionReplacedUnderItsOwnIdIsClosed() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            Self.touch("same-id", in: directory)
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            let proxy = MCPServerProxy(config: daemon)
            try await proxy.connect()
            _ = try await DaemonClient.runPrompt(
                on: proxy, stopReason: StopReasonBox(), sessionId: first.id,
                content: [.object(["type": .string("text"), "text": .string("hi")])], wait: true,
                permissionMode: "approve-all", nonInteractivePermissions: "deny")
            await proxy.disconnect()
            let held = try #require(await backend.heldConnection(first.id))
            #expect(try #require(SessionStore.loadRecord(first.id)).messages.isEmpty == false)

            let second = await Self.sessionsNew(agent, in: directory, daemon: daemon)
            #expect(second.code == 0 && second.id != first.id, "\(second.err)")
            let letGo = await (try? withTimeout(milliseconds: 10_000) { await held.waitUntilClosed() }) != nil
            #expect(letGo, "the replaced session's agent is still running")
            #expect(await backend.heldConnection(first.id) == nil)
            let prior = try #require(SessionStore.loadRecord(first.id))
            #expect(prior.closed == true && prior.messages.isEmpty == false)
            let current = try #require(SessionStore.loadRecord(second.id))
            #expect(current.closed != true && current.messages.isEmpty)
            #expect(current.acpSessionId == prior.acpSessionId)
            await backend.releaseAll()
        }
    }

    /// A daemon of another version is not worked through (#162): nothing is done, neither the
    /// new session made nor the one it would replace closed, and the user is told how to
    /// restart the daemon.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDaemonOfAnotherVersionHasNothingDone() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let daemon = DaemonOfAnotherVersion()

            let second = await Self.sessionsNew(agent, in: directory, daemon: .stdioHandles(server: daemon))
            #expect(second.code != 0)
            #expect(second.err.contains("DAEMON_VERSION_MISMATCH acpxd is version 1.0"), "\(second.err)")
            #expect(await daemon.closed.isEmpty)
            #expect(try #require(SessionStore.loadRecord(first.id)).closed != true)
            #expect(SessionStore.listSessions().count == 1)
        }
    }
}

/// An acpxd of another version, as `sessions new` meets one: it closes a session as that daemon
/// did, noting the record as it was when closed.
@MCPServer(name: "acpx")
actor DaemonOfAnotherVersion {
    private(set) var closed: [SessionRecord] = []

    /// Close a session.
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    @MCPTool
    func closeSession(sessionId: String) throws -> Bool {
        guard var record = SessionStore.loadRecord(sessionId) else { return false }
        closed.append(record)
        record.pid = nil
        record.closed = true
        record.closedAt = nowISO()
        try SessionStore.writeRecord(record)
        return true
    }
}
