@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// What acpxd offers an agent it connects, and how that agent signs in, are the `--no-fs`,
/// `--no-terminal` and `--auth-policy` of the prompt that started the session's owner, as acpx
/// builds its queue owner's client from the prompt that spawns it. A control with no owner
/// builds its own from its own flags, and `sessions new` keeps nothing of them (#246). Each
/// expectation is what acpx 0.19.3 offered the same agent.
@Suite(.serialized) struct OwnerClientOptionsTests {
    /// `initialize`'s `fs` and `terminal`, as acpx offered them.
    struct Offered: Equatable, CustomStringConvertible {
        var fs: Bool
        var terminal: Bool
        var description: String { "fs \(fs), terminal \(terminal)" }

        static let all = Offered(fs: true, terminal: true)
        static let none = Offered(fs: false, terminal: false)
    }

    /// The model fixture, logging every message it gets to `log` and taking sessions back.
    static func agent(log: URL) throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/model-agent.py")
        return "/usr/bin/env MODEL_AGENT_LOAD=1 MODEL_AGENT_LOG='\(log.path)' '\(python)' '\(fixture.path)'"
    }

    /// What each `initialize` the agent logged at `log` was offered, in order.
    static func offered(in log: URL) -> [Offered] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  message["method"] == .string("initialize"),
                  let capabilities = message["params"]?["clientCapabilities"]
            else { return nil }
            let fs = capabilities["fs"]
            return Offered(
                fs: fs?["readTextFile"] == .bool(true) && fs?["writeTextFile"] == .bool(true),
                terminal: capabilities["terminal"] == .bool(true))
        }
    }

    /// A queued turn's agent is offered what the prompt that started the owner asked for — on
    /// every reconnect while the owner lasts, whatever a later prompt asks — and an owner a
    /// later prompt starts is offered what that one asks for.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anOwnersAgentsAreOfferedWhatThePromptThatStartedItAsked() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("agent.log")
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: try Self.agent(log: log), cwd: directory.path)
            _ = try await daemon.runPrompt(sessionId: id, text: "hi", fs: false, terminal: false)
            // The owner's agent gone, a later prompt connects another for the same owner.
            await daemon.evict(id)
            _ = try await daemon.runPrompt(sessionId: id, text: "again")
            // A new owner, started by a prompt that asks for nothing.
            _ = try await daemon.releaseSession(sessionId: id)
            _ = try await daemon.runPrompt(sessionId: id, text: "later", terminal: false)
            await daemon.releaseAll()
            #expect(Self.offered(in: log) == [.all, .none, .none, Offered(fs: true, terminal: false)])
            let record = try String(contentsOf: ACPXPaths.sessionRecordPath(id), encoding: .utf8)
            #expect(!record.contains("client_capabilities"))
        }
    }

    /// So does the auth policy: an owner started under `--auth-policy fail` refuses an agent that
    /// advertises sign-in methods no credential matches — for a later prompt too, which that owner
    /// still holds — and an owner a later prompt starts signs in as configured, as acpx's do.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anOwnerSignsInAsThePromptThatStartedItAsked() async throws {
        let command = "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_AUTH_METHODS=token " + (try #require(mockCommand()))
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: directory.path)
            for (text, authPolicy) in [("hi", "fail"), ("again", nil)] {
                do {
                    _ = try await daemon.runPrompt(sessionId: id, text: text, authPolicy: authPolicy)
                    Issue.record("\(text): signed in")
                } catch {
                    #expect("\(error)".contains("no matching credentials found"), "\(text): \(error)")
                }
            }
            _ = try await daemon.releaseSession(sessionId: id)
            _ = try await daemon.runPrompt(sessionId: id, text: "later")
            await daemon.releaseAll()
        }
    }

    /// `acpx <flags> --agent <agent> <args>` against `backend`, the daemon running.
    static func acpx(_ args: [String], agent: String, cwd: URL, backend: ACPXDaemonBackend) async -> Int32 {
        let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
        return await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon) {
                    Console.$capture.withValue(Console.Capture()) {
                        runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                    }
                })
            }.start()
        }
    }

    /// The CLI sends its flags with a prompt and a control: `sessions new --no-fs` keeps nothing
    /// of it, a prompt's `--no-fs` reaches the owner it starts, and a control with no owner builds
    /// its agent's client from its own `--no-terminal` — as acpx offered them.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func theCLISendsItsFlagsWithAPromptAndAControl() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("agent.log")
        let agent = try Self.agent(log: log)
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            var codes: [Int32] = []
            codes.append(await Self.acpx(["--no-fs", "sessions", "new"], agent: agent, cwd: directory,
                                         backend: backend))
            codes.append(await Self.acpx(["prompt", "hi"], agent: agent, cwd: directory, backend: backend))
            let id = try #require(SessionStore.listSessions().first).acpxRecordId
            _ = try await backend.releaseSession(sessionId: id)
            codes.append(await Self.acpx(["--no-terminal", "set-mode", "plan"], agent: agent, cwd: directory,
                                         backend: backend))
            codes.append(await Self.acpx(["--no-fs", "prompt", "again"], agent: agent, cwd: directory,
                                         backend: backend))
            await backend.releaseAll()
            #expect(codes == [0, 0, 0, 0])
            #expect(Self.offered(in: log)
                == [Offered(fs: false, terminal: true), .all, Offered(fs: true, terminal: false),
                    Offered(fs: false, terminal: true)])
        }
    }
}
