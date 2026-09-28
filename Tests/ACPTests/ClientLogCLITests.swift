@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// Under `--verbose`, what acpx's client notes of an agent the CLI starts in its own process —
/// `exec`, `sessions new` — goes to stderr as `[acpx] <line>`, as acpx 0.19.3 writes it (#221):
/// the command it spawns, then the protocol version. Without `--verbose`, none of it.
@Suite(.serialized, .agentLane) struct ClientLogCLITests {
    @Test(.enabled(if: mockPythonAvailable), arguments: [["exec", "hi"], ["sessions", "new"]])
    func theClientsLinesGoToStderrUnderVerbose(_ command: [String]) async throws {
        let mock = try #require(mockCommand())
        let verbose = try await Self.run(["--verbose"] + command, agent: mock)
        #expect(verbose.code == 0, "\(verbose.err)")
        let lines = verbose.err.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(2)) == [
            "[acpx] spawning agent: \(try Self.spawned(mock))", "[acpx] initialized protocol version 1"
        ])
        let quiet = try await Self.run(command, agent: mock)
        #expect(quiet.code == 0, "\(quiet.err)")
        #expect(!quiet.err.contains("[acpx] spawning agent"))
        #expect(!quiet.err.contains("[acpx] initialized protocol version"))
    }

    /// The command as acpx's `logAgentLaunch` writes it: its parts, joined by spaces.
    private static func spawned(_ command: String) throws -> String {
        try AgentRegistry.commandLineParts(command).joined(separator: " ")
    }

    /// `acpx --agent <agent> <arguments>`, its stderr captured, on a thread of its own: the CLI
    /// blocks its thread until done, which the tasks' pool must not lose.
    private static func run(_ arguments: [String], agent: String) async throws -> (code: Int32, err: String) {
        let arguments = ["--approve-all", "--cwd", NSTemporaryDirectory(), "--agent", agent] + arguments
        return await withIsolatedStore {
            let capture = Console.Capture()
            let code: Int32 = await onThreadOfItsOwn {
                Console.$capture.withValue(capture) { runCommandLine(arguments) }
            }
            return (code, capture.err)
        }
    }
}
