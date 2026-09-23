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

    /// An existing directory on whatever platform the tests run on — "/tmp" is not one
    /// on Windows, where the working-directory check would then fire.
    private var workingDirectory: String { NSTemporaryDirectory() }

    @Test func aMissingWorkingDirectoryIsENOENT() throws {
        let launch = ProcessLaunch(
            executable: "/bin/echo", arguments: [], environment: ["PATH": "/bin"],
            workingDirectory: "/nonexistent/workspace")
        let failure = try #require(AgentLaunchPreflight.failure(for: launch))

        #expect(failure.detailCode == AgentLaunchError.spawnENOENT)
        #expect(failure.missingPath == "/nonexistent/workspace")
        #expect(failure.errorDescription?.hasSuffix(qualified) == true)
    }

    @Test func theBareMessageIsUsedWithoutTheEnoentDetail() {
        let error = AgentLaunchError(
            agentCommand: "claude acp", workingDirectory: "/tmp", detailCode: nil)
        #expect(error.errorDescription == "Failed to spawn agent command: claude acp")
    }

    // Executable resolution is POSIX-only: Windows matches a bare name against `PATHEXT`
    // through a `Path` variable with `;` separators, which the preflight deliberately
    // leaves to the spawn rather than guess at.
    #if !os(Windows)
    @Test func aMissingExecutableIsReportedAsSpawnENOENT() throws {
        let launch = ProcessLaunch(
            executable: "/nonexistent/definitely-not-here", arguments: ["acp"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: workingDirectory)
        // The configured command line, quoting included — acpx names the agent by that
        // string, not by a re-joined argv. Verified against acpx 0.19.1, which prints
        // `/nonexistent/definitely-not-here "acp"` for this very config.
        let failure = try #require(
            AgentLaunchPreflight.failure(
                for: launch, agentCommand: #"/nonexistent/definitely-not-here "acp""#))

        #expect(failure.detailCode == AgentLaunchError.spawnENOENT)
        #expect(failure.missingPath == "/nonexistent/definitely-not-here")
        #expect(
            failure.errorDescription
                == #"Failed to spawn agent command: /nonexistent/definitely-not-here "acp". "#
                    + qualified)
    }

    @Test func aBareNameIsLookedUpOnTheChildsOwnPath() throws {
        // Not on the child's PATH even though it exists elsewhere on this machine.
        let missing = ProcessLaunch(
            executable: "env", arguments: [], environment: ["PATH": "/nonexistent"],
            workingDirectory: workingDirectory)
        #expect(AgentLaunchPreflight.failure(for: missing)?.detailCode
            == AgentLaunchError.spawnENOENT)

        // …and found when the child's PATH does contain it.
        let found = ProcessLaunch(
            executable: "env", arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: workingDirectory)
        #expect(AgentLaunchPreflight.failure(for: found) == nil)
    }

    /// A file that is present but not executable failed on permissions, which is not the
    /// missing-path case acpx qualifies.
    @Test func anUnexecutableFileIsNotReportedAsAMissingPath() throws {
        let file = NSTemporaryDirectory() + "/agent-\(UUID().uuidString)"
        try "#!/bin/sh\necho hi\n".write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        defer { try? FileManager.default.removeItem(atPath: file) }

        let failure = try #require(
            AgentLaunchPreflight.failure(
                for: ProcessLaunch(
                    executable: file, arguments: [], environment: ["PATH": "/bin"],
                    workingDirectory: workingDirectory)))

        #expect(failure.detailCode == nil)
        #expect(failure.missingPath == nil)
        #expect(failure.errorDescription?.contains("could not start because") == false)
    }

    /// A script that is executable but whose `#!` interpreter is not: the spawn fails
    /// ENOENT, and the interpreter is the path worth naming.
    @Test func aMissingShebangInterpreterIsENOENT() throws {
        let script = NSTemporaryDirectory() + "/script-\(UUID().uuidString)"
        try "#!/nonexistent/interp -x\necho hi\n".write(
            toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let failure = try #require(
            AgentLaunchPreflight.failure(
                for: ProcessLaunch(
                    executable: script, arguments: [], environment: ["PATH": "/bin"],
                    workingDirectory: workingDirectory)))

        #expect(failure.detailCode == AgentLaunchError.spawnENOENT)
        #expect(failure.missingPath == "/nonexistent/interp")
    }

    @Test func aScriptWithAPresentInterpreterPassesPreflight() throws {
        let script = NSTemporaryDirectory() + "/ok-\(UUID().uuidString)"
        try "#!/bin/sh\necho hi\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }

        #expect(
            AgentLaunchPreflight.failure(
                for: ProcessLaunch(
                    executable: script, arguments: [], environment: ["PATH": "/bin"],
                    workingDirectory: workingDirectory)) == nil)
    }

    @Test func aViableLaunchPassesPreflight() {
        let launch = ProcessLaunch(
            executable: "/bin/echo", arguments: ["hi"], environment: ["PATH": "/bin"],
            workingDirectory: workingDirectory)
        #expect(AgentLaunchPreflight.failure(for: launch) == nil)
    }
    #endif
}
