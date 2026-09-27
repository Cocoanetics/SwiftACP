@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// The environment an agent acpxd starts starts over, as acpx's (#222): the calling CLI's —
/// and for a session a queue owner holds, the one of the CLI whose prompt started the owner.
extension DaemonToolsTests {
    /// A session's owner starts its agents over the environment of the prompt that started
    /// it: a later prompt's caller brings another, and the agent the owner starts anew for it —
    /// its first gone — starts over the owner's. Once the owner is gone, the next prompt starts
    /// one over its own caller's, as acpx's CLI spawns a session's queue owner with its own
    /// environment (#222).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSessionOwnersAgentsStartOverTheEnvironmentItStartedWith() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("starts.log")
        let command = try Self.notingAgent(in: directory, log: log)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            try await Self.queuedPrompt(daemon, id, caller: "first")
            // The agent exits once it has answered; the owner starts another for the next prompt.
            await Self.agentExited(daemon, id)
            try await Self.queuedPrompt(daemon, id, caller: "later")
            _ = try await daemon.releaseSession(sessionId: id)
            try await Self.queuedPrompt(daemon, id, caller: "fresh")
            #expect(Self.starts(log) == ["", "first", "first", "fresh"])
            await daemon.releaseAll()
        }
    }

    /// A control on a session no owner holds starts its agent over its caller's environment,
    /// as acpx runs such a control in the CLI's process; on a session an owner holds, the agent
    /// the owner starts anew for it starts over the owner's (#222).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlsAgentStartsOverItsCallersEnvironmentUnlessOwned() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("starts.log")
        let command = try Self.notingAgent(in: directory, log: log)
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.setMode(sessionId: id, modeId: "auto", environment: Self.environment("direct"))
            try await Self.queuedPrompt(daemon, id, caller: "owner")
            await Self.agentExited(daemon, id)
            _ = try await daemon.setMode(sessionId: id, modeId: "auto", environment: Self.environment("control"))
            #expect(Self.starts(log) == ["", "direct", "owner", "owner"])
            await daemon.releaseAll()
        }
    }

    /// The mock agent, noting the `ACPX_TEST_CALLER` it starts with — a shell appends
    /// `started with <value>` to `log`, then runs it — and exiting once it has answered a prompt.
    private static func notingAgent(in directory: URL, log: URL) throws -> String {
        let argv = try #require(mockArgv())
        let script = directory.appendingPathComponent("agent.sh")
        try """
            #!/bin/sh
            echo "started with ${ACPX_TEST_CALLER:-}" >> '\(log.path)'
            exec '\(argv[0])' '\(argv[1])'
            """.write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path, 0o755) == 0)
        return "/usr/bin/env MOCK_LOAD_SESSION=ok MOCK_EXIT_AFTER_PROMPTS=1 '\(script.path)'"
    }

    /// This process's environment with `ACPX_TEST_CALLER` set to `value`: a caller's own.
    private static func environment(_ value: String) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(["ACPX_TEST_CALLER": value]) { $1 }
    }

    /// A queued prompt from a caller whose environment has `ACPX_TEST_CALLER` set to `caller`.
    private static func queuedPrompt(_ daemon: ACPXDaemonBackend, _ id: String, caller: String) async throws {
        _ = try await daemon.runPrompt(
            sessionId: id, text: "hi", permissionMode: "approve-all", environment: environment(caller))
    }

    /// Wait until the agent held for `id` has exited, as the mock does once it has answered.
    private static func agentExited(_ daemon: ACPXDaemonBackend, _ id: String) async {
        await (await daemon.heldConnection(id))?.waitUntilClosed()
    }

    /// The `ACPX_TEST_CALLER` each agent started with, in order.
    private static func starts(_ log: URL) -> [String] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map {
            String($0.dropFirst("started with".count)).trimmingCharacters(in: .whitespaces)
        }
    }
}
