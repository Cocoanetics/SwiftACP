@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// acpx adapts an agent's launch to the agent (`src/acp/agent-command.ts`, 0.19.3) by the base
/// name of its command and its arguments (#248): Gemini's ACP flag by its version, Copilot's ACP
/// mode checked before it starts, Qoder given the session's limits on its command line, and Devin
/// met as the Windsurf client whose diagnostics it asks for.
@Suite(.serialized, .agentLane) struct AgentLaunchCompatTests {
    // MARK: The rules

    @Test func theAgentIsKnownByItsCommandsBaseNameAndArguments() {
        #expect(AgentLaunchCompat.isGemini("/usr/local/bin/Gemini", ["--experimental-acp"]))
        #expect(!AgentLaunchCompat.isGemini("gemini", ["chat"]))
        #expect(AgentLaunchCompat.isCopilot("COPILOT.EXE", ["--acp", "--stdio"]))
        #expect(!AgentLaunchCompat.isCopilot("copilot", ["--stdio"]))
        #expect(AgentLaunchCompat.isQoder("/opt/qodercli", ["--acp"]))
        #expect(AgentLaunchCompat.isDevin("devin", ["acp"]))
        #expect(AgentLaunchCompat.isDevin("devin", ["--experimental-acp"]))
        #expect(!AgentLaunchCompat.isDevin("devin", ["chat"]))
    }

    /// acpx's `detectGeminiVersion`: the first line with `<n>.<n>.<n>` on it, trimmed; `\d` is ASCII.
    @Test func aGeminiVersionIsTheFirstLineThatHasOne() {
        typealias Version = AgentLaunchCompat.Version
        let version = AgentLaunchCompat.geminiVersion(in:)
        #expect(version("gemini 0.32.9\n\n") == Version(raw: "gemini 0.32.9", parts: [0, 32, 9]))
        #expect(version("Loading\r\n  v1.2.3-beta \r\n") == Version(raw: "v1.2.3-beta", parts: [1, 2, 3]))
        #expect(AgentLaunchCompat.geminiVersion(in: "a1..2.3.4")?.parts == [2, 3, 4])
        #expect(AgentLaunchCompat.geminiVersion(in: "1.2\nunknown") == nil)
        #expect(AgentLaunchCompat.geminiVersion(in: "\u{661}.\u{662}.\u{663}") == nil)
        #expect(AgentLaunchCompat.geminiVersion(in: nil) == nil)
    }

    /// acpx's `resolveGeminiCommandArgs`: `gemini --acp` below 0.33.0 takes `--experimental-acp`,
    /// asked of `gemini --version` within 2 s; any other command is not asked.
    @Test func geminiBefore0_33TakesTheExperimentalFlag() async {
        func arguments(_ version: String?, command: String = "/opt/bin/gemini") async -> [String] {
            await AgentLaunchCompat.geminiArguments(command, ["--acp"]) { _, arguments, timeout in
                arguments == ["--version"] && timeout == 2_000 ? version : "unexpected probe"
            }
        }
        #expect(await arguments("gemini 0.32.9") == ["--experimental-acp"])
        #expect(await arguments("0.33.0") == ["--acp"])
        #expect(await arguments("unknown") == ["--acp"])
        #expect(await arguments(nil) == ["--acp"])
        #expect(await arguments("0.1.0", command: "/opt/bin/gemini-cli") == ["--acp"])
    }

    /// acpx's `buildQoderAcpCommandArgs`: the session's turn limit and tools, unless named already —
    /// Qoder's own tools in capitals.
    @Test func qoderTakesTheSessionsLimitsOnItsCommandLine() {
        let qoder = AgentLaunchCompat.qoderArguments(_:maxTurns:allowedTools:)
        #expect(qoder(["--acp"], 5, [" bash ", "Read", "custom tool"])
            == ["--acp", "--max-turns=5", "--allowed-tools=BASH,READ,custom tool"])
        #expect(qoder(["--acp", "--max-turns=9"], 3, ["ls"]) == ["--acp", "--max-turns=9", "--allowed-tools=LS"])
        #expect(qoder(["--acp", "--disallowed-tools", "x"], nil, ["grep"]) == ["--acp", "--disallowed-tools", "x"])
        #expect(qoder(["--acp"], nil, []) == ["--acp", "--allowed-tools="])
        #expect(qoder(["--acp"], nil, nil) == ["--acp"])
    }

    /// acpx's `ensureCopilotAcpSupport`: help that names no `--acp` refuses the launch; help that
    /// could not be had does not.
    @Test func copilotWithoutAnACPModeIsRefused() async throws {
        await #expect(throws: CopilotAcpUnsupportedError()) {
            try await AgentLaunchCompat.ensureCopilotSupport("copilot") { _, _, _ in "Usage: copilot [options]\n" }
        }
        try await AgentLaunchCompat.ensureCopilotSupport("copilot") { _, _, _ in "  --acp   Start as an ACP server" }
        try await AgentLaunchCompat.ensureCopilotSupport("copilot") { _, _, _ in nil }
    }

    @Test func devinIsMetAsWindsurf() throws {
        var capabilities = ClientCapabilities.acpx
        #expect(try JSONValue(encoding: capabilities)["_meta"] == nil)
        capabilities.meta = AgentLaunchCompat.devinCapabilitiesMeta
        #expect(try JSONValue(encoding: capabilities)["_meta"]
            == .object(["cognition.ai/requestDiagnostics": .bool(true)]))
        let info = AgentLaunchCompat.devinClientInfo(environment:)
        #expect(info([:]) == Implementation(name: "windsurf", version: "1.110.1"))
        #expect(info(["ACPX_DEVIN_WINDSURF_VERSION": "9.9.9"]).version == "9.9.9")
    }

    // MARK: The probe

    /// A probe that closed before anyone asked for its output still gives it (#263 review).
    @Test(.timeLimit(.minutes(1)))
    func aProbesOutputIsKeptForALateCaller() async {
        let capture = CommandProbeCapture()
        capture.append(.stdout, Array("gemini 0.32.9".utf8))
        capture.append(.stderr, Array("warn".utf8))
        capture.pipeClosed()
        capture.pipeClosed()
        capture.exited()
        #expect(await capture.output(within: 5_000) == "gemini 0.32.9\nwarn")
    }

    /// A probe whose caller is called off gives nothing at once, not at the end of its time
    /// (#263 review).
    @Test(.timeLimit(.minutes(1)))
    func aProbeCalledOffReturnsAtOnce() async {
        let started = ContinuousClock.now
        let probing = Task {
            await CommandProbe.output(
                of: "/bin/sleep", ["30"], cwd: NSTemporaryDirectory(), environment: nil, timeoutMilliseconds: 30_000)
        }
        probing.cancel()
        #expect(await probing.value == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // MARK: Launches

    /// A stand-in for an agent's CLI, `name` in `directory`: `--version` and `--help` print what is
    /// given, anything else is the mock agent — with `environment` its own.
    static func fakeCLI(
        _ name: String, in directory: URL, version: String = "0.40.0", help: String = "  --acp  ACP mode",
        environment: [String: String] = [:]
    ) throws -> String {
        let (python, fixture) = try (#require(mockArgv()?.first), #require(mockArgv()?.last))
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let exports = environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(quoted($0.value))" }
        let script = (["#!/bin/sh"] + exports + [
            "case \"$1\" in",
            "  --version) printf '%s\\n' \(quoted(version)); exit 0 ;;",
            "  --help) printf '%s\\n' \(quoted(help)); exit 0 ;;",
            "esac",
            "exec \(quoted(python)) \(quoted(fixture)) \"$@\""
        ]).joined(separator: "\n") + "\n"
        let path = directory.appendingPathComponent(name).path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Gemini below 0.33.0 is launched with `--experimental-acp`, as `gemini --version` said.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anOlderGeminiIsLaunchedWithTheExperimentalFlag() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argv = directory.appendingPathComponent("argv.log")
        let gemini = try Self.fakeCLI(
            "gemini", in: directory, version: "gemini 0.32.9", environment: ["MOCK_ARGV_LOG": argv.path])
        let agent = try await ACPAgent.launch(agent: "'\(gemini)' --acp", cwd: directory.path, permission: .approveAll)
        await agent.close()
        #expect(try String(contentsOf: argv, encoding: .utf8) == "[\"--experimental-acp\"]\n")
    }

    /// A launch called off while Gemini's `--version` still runs goes no further: the agent is
    /// never started (#263 review).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aLaunchCalledOffDuringItsProbeStartsNothing() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probing = try FIFOReader.make(name: "probing")
        let argv = directory.appendingPathComponent("argv.log")
        let (python, fixture) = try (#require(mockArgv()?.first), #require(mockArgv()?.last))
        let gemini = directory.appendingPathComponent("gemini").path
        let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then printf probing > '\(probing.path.path)'; exec sleep 30; fi
            MOCK_ARGV_LOG='\(argv.path)' exec '\(python)' '\(fixture)' "$@"

            """
        try script.write(toFile: gemini, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gemini)
        let launching = Task {
            try await ACPAgent.launch(agent: "'\(gemini)' --acp", cwd: directory.path, permission: .approveAll)
        }
        _ = await probing.next()
        launching.cancel()
        await #expect(throws: CancellationError.self) { _ = try await launching.value }
        #expect(!FileManager.default.fileExists(atPath: argv.path), "the agent was started")
    }

    /// Qoder is launched with the session's limits on its command line.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func qoderIsLaunchedWithTheSessionsLimits() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argv = directory.appendingPathComponent("argv.log")
        let qoder = try Self.fakeCLI("qodercli", in: directory, environment: ["MOCK_ARGV_LOG": argv.path])
        let agent = try await ACPAgent.launch(
            agent: "'\(qoder)' --acp", cwd: directory.path, permission: .approveAll,
            limits: SessionLimits(maxTurns: 5, allowedTools: ["bash", "custom"]))
        await agent.close()
        #expect(try String(contentsOf: argv, encoding: .utf8)
            == "[\"--acp\", \"--max-turns=5\", \"--allowed-tools=BASH,custom\"]\n")
    }

    /// Devin initializes as Windsurf, saying it answers Devin's diagnostics — and answers them.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func devinIsAnsweredAsWindsurf() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.log")
        let devin = try Self.fakeCLI(
            "devin", in: directory, environment: ["MOCK_WIRE_LOG": requests.path, "MOCK_DIAGNOSTICS": "1"])
        let agent = try await ACPAgent.launch(agent: "'\(devin)' acp", cwd: directory.path, permission: .approveAll)
        _ = try await agent.newSession(cwd: directory.path)
        await agent.close()
        let messages = try String(contentsOf: requests, encoding: .utf8).split(separator: "\n")
            .compactMap { WireJSON(parsing: Data($0.utf8)) }
        let initialize = try #require(messages.first { $0["method"]?.stringValue == "initialize" })
        #expect(initialize["params"]?["clientInfo"]?.stringified == #"{"name":"windsurf","version":"1.110.1"}"#)
        #expect(initialize["params"]?["clientCapabilities"]?["_meta"]?.stringified
            == #"{"cognition.ai/requestDiagnostics":true}"#)
        let answer = try #require(messages.first { $0["id"]?.stringValue == "mock-diagnostics" })
        #expect(answer["result"]?.stringified == "{}")
    }

    /// Copilot without an ACP mode is never started: the CLI fails with acpx's
    /// `COPILOT_ACP_UNSUPPORTED`, exit 1.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func copilotWithoutAnACPModeIsNeverStarted() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argv = directory.appendingPathComponent("argv.log")
        let copilot = try Self.fakeCLI(
            "copilot", in: directory, help: "Usage: copilot [options]", environment: ["MOCK_ARGV_LOG": argv.path])
        let run = await withIsolatedStore {
            await CLIParityTests.run([
                "--approve-all", "--format", "json", "--cwd", directory.path,
                "--agent", "'\(copilot)' --acp --stdio", "exec", "hi"
            ])
        }
        #expect(run.code == ExitCodes.error)
        let error = try #require(WireJSON(parsing: Data(run.out.utf8))?["error"])
        #expect(error["code"] == .number(-32603))
        #expect(error["message"]?.stringValue == CopilotAcpUnsupportedError().errorDescription)
        #expect(error["data"]?["detailCode"]?.stringValue == "COPILOT_ACP_UNSUPPORTED")
        #expect(error["data"]?["retryable"] == .bool(false))
        #expect(!FileManager.default.fileExists(atPath: argv.path), "the agent was started")
    }
}
