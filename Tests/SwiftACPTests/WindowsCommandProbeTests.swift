#if os(Windows)
@testable import SwiftACP
import Foundation
import Testing

/// The launch probes on Windows (#265): `gemini --version` and `copilot --help`, run as acpx runs
/// them there, an npm `.cmd` shim through `cmd.exe`.
@Suite(.timeLimit(.minutes(1)))
struct WindowsCommandProbeTests {
    /// A directory of its own, with a space in its name, holding `scripts` (name → lines), and
    /// an environment with it first on `PATH`.
    private struct Scripts {
        let directory: String
        let environment: [String: String]

        init(_ scripts: [String: [String]]) throws {
            var temporary = NSTemporaryDirectory()
            while temporary.hasSuffix("\\") || temporary.hasSuffix("/") { temporary.removeLast() }
            directory = temporary + "\\swiftacp probe \(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, lines) in scripts {
                let text = (["@echo off"] + lines).joined(separator: "\r\n") + "\r\n"
                FileManager.default.createFile(atPath: directory + "\\" + name, contents: Data(text.utf8))
            }
            let inherited = ProcessInfo.processInfo.environment
            var environment = inherited.filter { $0.key.uppercased() != "PATH" }
            environment["PATH"] = directory + ";" + (WindowsSpawnCommand.value(of: "PATH", in: inherited) ?? "")
            self.environment = environment
        }

        func probe(_ command: String, _ arguments: [String], timeout: Int = 10_000) async -> String? {
            await CommandProbe.output(
                of: command, arguments, cwd: directory, environment: environment, timeoutMilliseconds: timeout)
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// A shim found on `PATH` answers: stdout, a newline, then stderr, as acpx's capture joins them.
    @Test func aShimOnPathAnswers() async throws {
        let scripts = try Scripts(["fakegemini.cmd": ["echo 1.2.3", ">&2 echo warn"]])
        defer { scripts.remove() }
        #expect(await scripts.probe("fakegemini", ["--version"]) == "1.2.3\r\n\nwarn\r\n")
    }

    /// Arguments reach a shim as they were given, cmd.exe's metacharacters and spaces in them too.
    @Test func argumentsReachAShimIntact() async throws {
        let scripts = try Scripts(["echoargs.cmd": ["echo [%1] [%2]"]])
        defer { scripts.remove() }
        #expect(await scripts.probe("echoargs", ["a&b", "x y"]) == "[\"a&b\"] [\"x y\"]\r\n\n")
    }

    /// A program that is no shim starts directly, its arguments quoted for it.
    @Test func aProgramStartsDirectly() async throws {
        let scripts = try Scripts([:])
        defer { scripts.remove() }
        #expect(await scripts.probe("cmd", ["/d", "/c", "echo hi"]) == "hi\r\n\n")
    }

    /// Nothing found for the command: no answer, as acpx's probe gets none from a spawn that fails.
    @Test func aMissingProgramGivesNoAnswer() async throws {
        let scripts = try Scripts([:])
        defer { scripts.remove() }
        #expect(await scripts.probe("swiftacp-no-such-probe", ["--version"]) == nil)
    }

    /// A shim named by a path that is not there still goes to cmd.exe, as acpx sends it, and
    /// cmd.exe says so on stderr: an answer with nothing on stdout.
    @Test func aMissingShimStillRuns() async throws {
        let scripts = try Scripts([:])
        defer { scripts.remove() }
        let output = await scripts.probe(scripts.directory + "\\missing.cmd", ["--version"])
        #expect(output?.hasPrefix("\n") == true)
    }

    /// A probe past its time gives no answer, and everything it started is ended with it.
    @Test func aProbePastItsTimeEndsWithAllItStarted() async throws {
        let scripts = try Scripts(["slow.cmd": ["ping -n 30 127.0.0.1 >nul", "echo late"]])
        defer { scripts.remove() }
        let left = Left()
        let started = ContinuousClock.now
        let output = await CommandProbe.output(
            of: "slow", ["--version"], cwd: scripts.directory, environment: scripts.environment,
            timeoutMilliseconds: 500, retired: { left.set($0) })
        #expect(output == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(left.value == 0)
    }

    /// The launch asks Gemini's shim its version: one before 0.33.0 takes `--experimental-acp`.
    @Test func theLaunchAsksGeminisShim() async throws {
        let scripts = try Scripts(["gemini.cmd": ["echo 0.30.0"]])
        defer { scripts.remove() }
        let launch = ProcessLaunch(
            executable: "gemini", environment: scripts.environment, workingDirectory: scripts.directory)
        let arguments = await AgentLaunchCompat.geminiArguments("gemini", ["--acp"], probe: ACPAgent.probe(for: launch))
        #expect(arguments == ["--experimental-acp"])
    }

    /// The launch asks Copilot's shim for its help, and refuses a CLI that has no `--acp`.
    @Test func theLaunchRefusesACopilotWithoutAcp() async throws {
        let scripts = try Scripts(["copilot.cmd": ["echo Usage: copilot [options]"]])
        defer { scripts.remove() }
        let launch = ProcessLaunch(
            executable: "copilot", environment: scripts.environment, workingDirectory: scripts.directory)
        await #expect(throws: CopilotAcpUnsupportedError.self) {
            try await AgentLaunchCompat.ensureCopilotSupport("copilot", probe: ACPAgent.probe(for: launch))
        }
    }
}

/// What a probe's retirement left running.
private final class Left: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int?

    func set(_ value: Int) {
        lock.withLock { count = value }
    }

    var value: Int? {
        lock.withLock { count }
    }
}
#endif
