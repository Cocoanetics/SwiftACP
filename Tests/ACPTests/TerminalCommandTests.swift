@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `exec` against an agent that runs `echo hello terminal` through the client's
/// terminal (#82): advertised and served as acpx 0.19.1 serves it, refused under
/// `--deny-all` with exit 5, and withheld by `--no-terminal`.
struct TerminalCommandTests {
    struct Ran {
        var code: Int32
        var out: String
    }

    static func run(_ flags: [String]) async throws -> Ran {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let command = "/usr/bin/env MOCK_TERMINAL='[\"echo\",\"hello\",\"terminal\"]' '\(python)' '\(fixture.path)'"
        return await withIsolatedStore {
            let capture = Console.Capture()
            let code = Console.$capture.withValue(capture) {
                runCommandLine(flags + ["--agent", command, "exec", "go"])
            }
            return Ran(code: code, out: capture.out)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func approveAllRunsTheCommand() async throws {
        let ran = try await Self.run(["--approve-all"])
        #expect(ran.code == ExitCodes.success)
        #expect(ran.out.contains("[client] terminal/create (running)"))
        #expect(ran.out.contains("ran:0:hello terminal\n"))
    }

    /// Refused in acpx's words, shown as the stream shows any refusal, and the run exits
    /// 5 since the only permission it needed was denied.
    @Test(.enabled(if: mockPythonAvailable))
    func denyAllRefusesTheCommand() async throws {
        let ran = try await Self.run(["--deny-all"])
        #expect(ran.code == ExitCodes.permissionDenied)
        #expect(ran.out.contains("[error] RUNTIME: Permission denied for terminal/create"))
        #expect(ran.out.contains("error:Permission denied for terminal/create"))
    }

    /// A command the agent starts while it answers `initialize` ends when the launch
    /// then fails (#101 review): nothing else would ever reach its terminal. The command
    /// prints its pid, which the agent logs before failing `initialize`.
    @Test(.enabled(if: mockPythonAvailable))
    func aFailedLaunchEndsTheCommandTheAgentStarted() async throws {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let log = NSTemporaryDirectory() + "launch-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let command = "/usr/bin/env MOCK_TERMINAL='[\"sh\",\"-c\",\"echo $$; exec sleep 30\"]' "
            + "MOCK_TERMINAL_ON_INITIALIZE=1 MOCK_TERMINAL_LOG='\(log)' '\(python)' '\(fixture.path)'"
        await #expect(throws: (any Error).self) {
            _ = try await ACPAgent.launch(
                agent: command, permission: .approveAll, capabilities: .acpx, inheritStderr: false)
        }
        let pid = try #require(pid_t(try String(contentsOfFile: log, encoding: .utf8).javaScriptTrimmed))
        #expect(kill(pid, 0) != 0)
    }

    /// acpx advertises terminals by default; `--no-terminal` withholds them, and the
    /// agent calling anyway hears the ACP SDK's method-not-found.
    @Test(.enabled(if: mockPythonAvailable))
    func noTerminalWithholdsTheCapability() async throws {
        let advertised = try await Self.run(["--format", "json", "--approve-all"]).out
        #expect(advertised.contains(#""terminal":true"#))

        let withheld = try await Self.run(["--format", "json", "--approve-all", "--no-terminal"]).out
        #expect(withheld.contains(#""terminal":false"#))
        #expect(withheld.contains(#"error:\"Method not found\": terminal/create"#))
    }
}
