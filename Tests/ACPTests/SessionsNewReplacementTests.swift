@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
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

    /// `acpx --agent <agent> --cwd <directory> --format quiet sessions new`: its exit code,
    /// and the new session's id.
    private static func sessionsNew(_ agent: String, in directory: URL) async -> (code: Int32, id: String) {
        let capture = Console.Capture()
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: Console.$capture.withValue(capture) {
                    runCommandLine(["--agent", agent, "--cwd", directory.path, "--format", "quiet", "sessions", "new"])
                })
            }.start()
        }
        return (code, capture.out.trimmingCharacters(in: .whitespacesAndNewlines))
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
}
