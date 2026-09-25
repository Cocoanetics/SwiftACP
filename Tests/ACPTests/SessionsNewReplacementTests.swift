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
/// old session open. A new session under the replaced one's id is spared the close that
/// would end it (openclaw/acpx#805).
@Suite(.serialized) struct SessionsNewReplacementTests {
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
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon) {
                    Console.$capture.withValue(capture) {
                        runCommandLine(
                            ["--agent", agent, "--cwd", directory.path, "--format", "quiet", "sessions", "new"])
                    }
                })
            }.start()
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

    /// A replaced record that moved to another ACP session (a reconnect's fallback, an
    /// import) keeps its own id: when the new session gets the ACP id it moved to, the
    /// replaced record is the one closed, and the new one stays open (Codex review on #184).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aReplacedRecordThatMovedIsClosedByItsOwnId() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            var moved = try #require(SessionStore.loadRecord(first.id))
            moved.acpSessionId = "mock-session-1"
            try SessionStore.writeRecord(moved)
            Self.touch("same-id", in: directory)
            let second = await Self.sessionsNew(agent, in: directory)
            #expect(second.code == 0)
            #expect(second.id == "mock-session-1" && second.id != first.id)
            #expect(try #require(SessionStore.loadRecord(first.id)).closed == true)
            #expect(try #require(SessionStore.loadRecord(second.id)).closed != true)
        }
    }

    /// An agent that gives every session the same id makes the new session the replaced
    /// record anew; it stays open, where acpx 0.19.3 closes it (openclaw/acpx#805).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aNewSessionUnderTheReplacedIdStaysOpen() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            Self.touch("same-id", in: directory)
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let second = await Self.sessionsNew(agent, in: directory)
            #expect(first.code == 0 && second.code == 0)
            #expect(first.id == second.id)
            #expect(try #require(SessionStore.loadRecord(second.id)).closed != true)
        }
    }

    /// A daemon holding the replaced session lets its agent go when the new session takes
    /// the session's id, and the session stays open: the new one, with none of the
    /// conversation the old agent had.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aHeldSessionReplacedUnderItsOwnIdLetsItsAgentGo() async throws {
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
            #expect(second.code == 0 && second.id == first.id)
            let letGo = await (try? withTimeout(milliseconds: 10_000) { await held.waitUntilClosed() }) != nil
            #expect(letGo, "the replaced session's agent is still running")
            #expect(await backend.heldConnection(first.id) == nil)
            let kept = try #require(SessionStore.loadRecord(second.id))
            #expect(kept.closed != true)
            #expect(kept.messages.isEmpty)
            await backend.releaseAll()
        }
    }

    /// An acpxd from before `releaseSession` (#162) lets a session's agent go only by closing
    /// the session. With one running, the replaced session is closed before the new one is
    /// created, so that close cannot reach a new session under the same id (Codex review
    /// on #184).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDaemonFromBeforeReleaseSessionHasTheReplacedSessionClosedFirst() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            Self.touch("same-id", in: directory)
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let replaced = try #require(SessionStore.loadRecord(first.id))
            let daemon = DaemonBeforeRelease()

            let second = await Self.sessionsNew(agent, in: directory, daemon: .stdioHandles(server: daemon))
            #expect(second.code == 0 && second.id == first.id)
            // What it closed was the replaced session, before the new one was written in its place.
            #expect(await daemon.closed.map(\.createdAt) == [replaced.createdAt])
            let kept = try #require(SessionStore.loadRecord(second.id))
            #expect(kept.closed != true)
            #expect(kept.createdAt != replaced.createdAt)
        }
    }

    /// A daemon that fails to let the replaced session's agent go may still hold it: that
    /// is an error, and the session is not closed in its place, which could end the new
    /// session too.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aDaemonThatFailsToLetTheAgentGoIsReported() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            Self.touch("same-id", in: directory)
            let agent = try Self.agent(in: directory)
            let first = await Self.sessionsNew(agent, in: directory)
            let daemon = DaemonFailingRelease()

            let second = await Self.sessionsNew(agent, in: directory, daemon: .stdioHandles(server: daemon))
            #expect(second.code != 0)
            #expect(second.err.contains("acpxd could not let go of session \(first.id)'s agent"))
            #expect(await daemon.closed.isEmpty)
            #expect(try #require(SessionStore.loadRecord(first.id)).closed != true)
        }
    }

    /// The running daemon is told apart by its tools: today's has `releaseSession`, one
    /// from before it has not, and one that cannot list them is taken for the older.
    @Test func aDaemonFromBeforeReleaseSessionIsToldApart() async throws {
        let current = MCPServerProxy(
            config: .stdioHandles(server: ACPXDaemon(backend: ACPXDaemonBackend(inheritAgentStderr: false))))
        try await current.connect()
        let older = MCPServerProxy(config: .stdioHandles(server: DaemonBeforeRelease()))
        try await older.connect()

        #expect(await DaemonClient.lacksRelease(on: current) == false)
        #expect(await DaemonClient.lacksRelease(on: older))
        await current.disconnect()
        await older.disconnect()
        #expect(await DaemonClient.lacksRelease(on: current))
    }
}

/// An acpxd from before `releaseSession` (#162), as `sessions new` meets one: it closes a
/// session as that daemon did, noting the record as it was when closed.
@MCPServer(name: "acpx")
actor DaemonBeforeRelease {
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

/// An acpxd whose `releaseSession` fails, noting any session it is asked to close.
@MCPServer(name: "acpx")
actor DaemonFailingRelease {
    private(set) var closed: [String] = []

    struct Failure: LocalizedError {
        var errorDescription: String? { "the agent would not go" }
    }

    /// Let a session's agent go.
    /// - Parameter sessionId: the acpx record id.
    @MCPTool
    func releaseSession(sessionId: String) throws -> Bool { throw Failure() }

    /// Close a session.
    /// - Parameter sessionId: the acpx record id or the ACP session id.
    @MCPTool
    func closeSession(sessionId: String) -> Bool {
        closed.append(sessionId)
        return true
    }
}
