#if os(Windows)
import Foundation
@testable import SwiftACP
import Testing

/// Agents on Windows run under ``AgentProcessTransport``, as on macOS and Linux (#272): how an agent
/// ends is known and named as acpx names it, what it wrote before its exit is read first, closing
/// it ends it, and a `.cmd` shim runs through `cmd.exe`. The messages are acpx's for the same
/// `exit-agent.py` (`AgentEndTests`). On Windows, Node's `kill` terminates a process for `SIGTERM`
/// as for `SIGKILL`, so an agent cannot outlast the first and is reported ended by it.
@Suite(.timeLimit(.minutes(1)))
struct WindowsAgentTransportTests {
    static func launch(_ variables: [String: String]) async throws -> ACPAgent {
        let python = try #require(mockPython)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/exit-agent.py")
        return try await ACPAgent.launch(
            agent: "exit-agent", argv: [python, fixture.path], cwd: NSTemporaryDirectory(), permission: .approveAll,
            environment: ProcessInfo.processInfo.environment.merging(variables) { $1 }, inheritStderr: false)
    }

    @Test(.enabled(if: mockPythonAvailable))
    func anAgentExitingMidTurnSaysHowItEnded() async throws {
        let agent = try await Self.launch(["EXIT_AGENT_ON": "prompt", "EXIT_AGENT_CODE": "3"])
        let session = try await agent.newSession()
        let error = await #expect(throws: AgentDisconnectedError.self) {
            _ = try await session.prompt([.text("hi")])
        }
        #expect(error?.localizedDescription
            == "ACP agent disconnected during request (process_exit, exit=3, signal=null)")
        let lifecycle = try #require(agent.lifecycle)
        #expect(!lifecycle.running)
        #expect(lifecycle.lastExit?.exitCode == 3)
        #expect(lifecycle.lastExit?.unexpectedDuringPrompt == true)
        await agent.close()
    }

    /// acpx's `AgentStartupError`: the exit, then the agent's stderr with its runs of whitespace
    /// made one space.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentExitingInItsHandshakeSaysWhy() async throws {
        let error = await #expect(throws: AgentStartupError.self) {
            _ = try await Self.launch(["EXIT_AGENT_ON": "initialize", "EXIT_AGENT_STDERR": "boom\n  second   line\n"])
        }
        #expect(error?.localizedDescription
            == "ACP agent exited before initialize completed (exit=3, signal=null): boom second line")
    }

    /// What the agent wrote before it exited is all read before its end is reported.
    @Test(.enabled(if: mockPythonAvailable))
    func anAnswerWrittenBeforeTheExitArrives() async throws {
        let agent = try await Self.launch(["EXIT_AGENT_ANSWER_THEN_EXIT": "1"])
        let session = try await agent.newSession()
        let outcome = try await session.run("hi")
        #expect(outcome.stopReason == .endTurn)
        await agent.connection.waitUntilClosed()
        let exit = try #require(agent.lifecycle?.lastExit)
        #expect(exit.reason == .processExit)
        #expect(exit.exitCode == 0)
        #expect(!exit.unexpectedDuringPrompt)
        await agent.close()
    }

    /// An agent that runs on once its stdin ends is ended as acpx ends it, and that is its end: the
    /// client's own doing, never unexpected.
    @Test(.enabled(if: mockPythonAvailable), arguments: ["EXIT_AGENT_LINGER", "EXIT_AGENT_STUBBORN"])
    func closingAnAgentThatRunsOnRecordsTheSignalThatEndedIt(_ runsOn: String) async throws {
        let agent = try await Self.launch([runsOn: "1"])
        await agent.close()
        let exit = try #require(agent.lifecycle?.lastExit)
        #expect(exit.reason == .processExit)
        #expect(exit.signal == "SIGTERM")
        #expect(exit.exitCode == nil)
        #expect(!exit.unexpectedDuringPrompt)
    }

    /// An agent behind a `.cmd` shim, in a directory with a space in its name, runs through
    /// `cmd.exe` as acpx starts it, and a turn goes through.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentBehindACmdShimRuns() async throws {
        let python = try #require(mockPython)
        let mock = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/mock-agent.py").path
        var temporary = NSTemporaryDirectory()
        while temporary.hasSuffix("\\") || temporary.hasSuffix("/") { temporary.removeLast() }
        let directory = temporary + "\\swiftacp agent \(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let shim = directory + "\\mock agent.cmd"
        let script = "@echo off\r\n\"\(python)\" \"\(mock)\" %*\r\n"
        FileManager.default.createFile(atPath: shim, contents: Data(script.utf8))

        let agent = try await ACPAgent.launch(
            agent: "mock", argv: [shim], cwd: directory, permission: .approveAll, inheritStderr: false)
        let session = try await agent.newSession()
        let outcome = try await session.run("hi")
        #expect(outcome.stopReason == .endTurn)
        #expect(agent.lifecycle?.running == true)
        await agent.close()
        #expect(agent.lifecycle?.running == false)
    }
}
#endif
