@testable import ACPXCore
@testable import acpxd
import Foundation
@testable import SwiftACP
import Testing

/// An agent that exits while acpxd holds its session (issue #55). acpx's queue owner
/// notices — `hasLiveConnection` is false once the child exits — and starts a new
/// client for the next operation; the daemon must not keep sending into the dead one.
extension DaemonToolsTests {
    /// The next turn reconnects and takes the session back, instead of failing with
    /// "The JSON-RPC connection is closed" — and every turn after it.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnAfterTheAgentExitedReconnects() async throws {
        try await withLoggedMock(loadMode: "ok", exitAfterPrompts: 1) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            // The mock exits after answering; wait until the held connection has seen it.
            await daemon.live[id]?.agent.connection.waitUntilClosed()

            let answer = try await daemon.runPrompt(sessionId: id, text: "second")
            #expect(!answer.isEmpty)
            #expect(try methods() == [
                "session/new", "session/load", "session/prompt", "session/load", "session/prompt"
            ])
        }
    }

    /// A control reconnecting an agent that exited must get the *same* session back:
    /// acpx runs an idle owner's controls `same-session-only`, so a session the new
    /// process cannot load is refused rather than silently replaced. A turn in the same
    /// position may still start over.
    @Test(.enabled(if: mockPythonAvailable))
    func aControlAfterTheAgentExitedKeepsTheSession() async throws {
        try await withLoggedMock(loadMode: "gone", exitAfterPrompts: 1) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            await daemon.live[id]?.agent.connection.waitUntilClosed()
            let sessionsBefore = try methods().filter { $0 == "session/new" }.count

            let error = await #expect(throws: DaemonError.self) {
                _ = try await daemon.setMode(sessionId: id, modeId: "auto")
            }
            #expect(error?.localizedDescription.hasPrefix(
                "Persistent ACP session \(id) could not be resumed") == true)
            #expect(try methods().filter { $0 == "session/new" }.count == sessionsBefore)

            let answer = try await daemon.runPrompt(sessionId: id, text: "second")
            #expect(!answer.isEmpty)
        }
    }

    /// The liveness check can race the exit: the agent's end has been read but not yet
    /// recorded when `ensure` looks. None of the turn reaches the dead agent, so it goes
    /// to a fresh launch instead of failing.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnRacingTheExitGoesToAFreshLaunch() async throws {
        try await withLoggedMock(loadMode: "ok", exitAfterPrompts: 1) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            let connection = try #require(await daemon.live[id]?.agent.connection)
            await connection.waitUntilClosed()
            await connection.forgetClosedForTesting()

            let answer = try await daemon.runPrompt(sessionId: id, text: "second")
            #expect(!answer.isEmpty)
            #expect(try methods() == [
                "session/new", "session/load", "session/prompt", "session/load", "session/prompt"
            ])
        }
    }

    /// A turn that did reach the agent before it died is not sent again: the agent may
    /// have acted on it. The failure is reported instead.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnTheAgentReceivedIsNotSentTwice() async throws {
        try await withLoggedMock(loadMode: "ok", exitOnPrompt: 2) { command, methods in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            await #expect(throws: (any Error).self) {
                _ = try await daemon.runPrompt(sessionId: id, text: "second")
            }
            #expect(try methods() == ["session/new", "session/load", "session/prompt", "session/prompt"])
        }
    }

    /// An agent that exited has no turn to cancel.
    @Test(.enabled(if: mockPythonAvailable))
    func thereIsNothingToCancelOnAnAgentThatExited() async throws {
        try await withLoggedMock(loadMode: "ok", exitAfterPrompts: 1) { command, _ in
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            await daemon.live[id]?.agent.connection.waitUntilClosed()
            #expect(try await daemon.cancelSession(sessionId: id) == false)
        }
    }
}
