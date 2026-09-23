@testable import SwiftACP
import Foundation
import Testing

/// What a user is told when an agent adapter cannot be launched. A missing binary used
/// to surface as "The operation couldn't be completed. (Subprocess.SubprocessError
/// error 1.)"; acpx names the command and what to check (`AgentSpawnError` +
/// `AGENT_SPAWN_ENOENT`, issue #28).
struct AgentLaunchErrorTests {
    /// acpx's qualified wording, verbatim — the reason this test spells it out in full.
    private let qualified =
        "The agent process could not start because a required executable, interpreter,"
        + " working directory, or other launch path was not found. Check the command,"
        + " effective PATH, and working directory, or verify the custom agent's configured"
        + " argv."

    @Test func aMissingExecutableIsReportedAsSpawnENOENT() throws {
        let launch = ProcessLaunch(
            executable: "/nonexistent/definitely-not-here", arguments: ["acp"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/tmp")
        let failure = try #require(AgentLaunchPreflight.failure(for: launch))

        #expect(failure.detailCode == AgentLaunchError.spawnENOENT)
        #expect(failure.missingPath == "/nonexistent/definitely-not-here")
        #expect(
            failure.errorDescription
                == "Failed to spawn agent command: /nonexistent/definitely-not-here acp. "
                    + qualified)
    }

    @Test func aBareNameIsLookedUpOnTheChildsOwnPath() throws {
        // Not on the child's PATH even though it exists elsewhere on this machine.
        let missing = ProcessLaunch(
            executable: "env", arguments: [], environment: ["PATH": "/nonexistent"],
            workingDirectory: "/tmp")
        #expect(AgentLaunchPreflight.failure(for: missing)?.detailCode
            == AgentLaunchError.spawnENOENT)

        // …and found when the child's PATH does contain it.
        let found = ProcessLaunch(
            executable: "env", arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp")
        #expect(AgentLaunchPreflight.failure(for: found) == nil)
    }

    @Test func aMissingWorkingDirectoryIsAlsoENOENT() throws {
        let launch = ProcessLaunch(
            executable: "/bin/echo", arguments: [], environment: ["PATH": "/bin"],
            workingDirectory: "/nonexistent/workspace")
        let failure = try #require(AgentLaunchPreflight.failure(for: launch))

        #expect(failure.missingPath == "/nonexistent/workspace")
        #expect(failure.errorDescription?.hasSuffix(qualified) == true)
    }

    @Test func theBareMessageIsUsedWithoutTheEnoentDetail() {
        let error = AgentLaunchError(
            agentCommand: "claude acp", workingDirectory: "/tmp", detailCode: nil)
        #expect(error.errorDescription == "Failed to spawn agent command: claude acp")
    }

    @Test func aViableLaunchPassesPreflight() {
        let launch = ProcessLaunch(
            executable: "/bin/echo", arguments: ["hi"], environment: ["PATH": "/bin"],
            workingDirectory: "/tmp")
        #expect(AgentLaunchPreflight.failure(for: launch) == nil)
    }
}
