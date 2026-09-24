@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// `prompt --model` puts the model on the session before the prompt, as acpx's queue
/// owner does (`applyPromptModelIfAdvertised`, #92): checked against what the session
/// advertises, not sent when it is already current, pinned in the record either way —
/// and the reconnect leaves the saved model and options alone, which the turn replaces.
/// Each expectation is what acpx 0.19.1 sent `model-agent.py` for the same record.
extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsModelGoesOnBeforeItsPrompt() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession(load: true)
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: id, text: "hi", model: "m2")
            #expect(try Self.modelAgentRequests(log) == [
                "session/load", "session/set_config_option model=m2", "session/prompt"
            ])
            #expect(SessionStore.loadRecord(id)?.acpx?.currentModelId == "m2")
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsModelAlreadyCurrentIsPinnedWithoutAsking() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession()
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: id, text: "hi", model: "m1")
            // The session the reconnect starts is started on the turn's model.
            let created = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .first { $0.contains(#""method": "session/new""#) }
            #expect(created?.contains(#""model": "m1""#) == true)
            #expect(try Self.modelAgentRequests(log) == ["session/new", "session/prompt"])
            #expect(SessionStore.loadRecord(id)?.acpx?.sessionOptions?.model == "m1")
        }
    }

    /// A model the session does not offer fails the turn before the prompt goes out;
    /// the pin stays.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsUnusableModelFailsBeforeThePrompt() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession(load: true)
            let failure = await #expect(throws: ModelApplication.UnsupportedError.self) {
                _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                    .runPrompt(sessionId: id, text: "hi", model: "bogus")
            }
            #expect(failure?.localizedDescription == """
                Cannot apply --model "bogus": the ACP agent did not advertise that model. Available models: m1, m2.
                """)
            #expect(try Self.modelAgentRequests(log) == ["session/load"])
            #expect(SessionStore.loadRecord(id)?.acpx?.sessionOptions?.model == "m2")
        }
    }

    /// The saved options are not put back ahead of a turn's model: the model's reply
    /// decides what they are now.
    @Test(.enabled(if: mockPythonAvailable))
    func aTurnsModelReplacesTheSavedSelections() async throws {
        try await withIsolatedStore {
            let (id, log) = try await pinnedSession { acpx in acpx.desiredConfigOptions = ["effort": "high"] }
            _ = try await ACPXDaemonBackend(inheritAgentStderr: false)
                .runPrompt(sessionId: id, text: "hi", model: "m2")
            #expect(try Self.modelAgentRequests(log) == [
                "session/new", "session/set_config_option model=m2", "session/prompt"
            ])
            #expect(SessionStore.loadRecord(id)?.acpx?.desiredConfigOptions == ["effort": "low"])
        }
    }

    /// A held agent that exits on the turn's model request leaves the turn to a fresh
    /// launch, as one that exits before the prompt does: the prompt never reached it
    /// (#105 review). There the model is already current, so it is not asked again.
    @Test(.enabled(if: mockPythonAvailable))
    func aHeldAgentExitingOnTheTurnsModelLeavesTheTurnToAFreshLaunch() async throws {
        try await withIsolatedStore {
            let armed = ACPXPaths.baseDir.appendingPathComponent("exit-on-model")
            let (id, log) = try await pinnedSession(
                load: true, environment: "MODEL_AGENT_EXIT_ON_MODEL='\(armed.path)' ")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            _ = try await daemon.runPrompt(sessionId: id, text: "first")
            try "".write(to: armed, atomically: true, encoding: .utf8)
            try "".write(to: log, atomically: true, encoding: .utf8)

            _ = try await daemon.runPrompt(sessionId: id, text: "second", model: "m1")
            #expect(try Self.modelAgentRequests(log) == [
                "session/set_config_option model=m1", "session/load", "session/prompt"
            ])
            #expect(SessionStore.loadRecord(id)?.acpx?.sessionOptions?.model == "m1")
        }
    }
}
