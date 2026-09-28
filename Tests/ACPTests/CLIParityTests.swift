@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// CLI behaviours found by auditing acpx 0.19.3's CLI against SwiftACP's (#250, #252).
@Suite(.serialized) struct CLIParityTests {
    struct Run {
        var code: Int32
        var out: String
        var err: String
    }

    static func run(_ arguments: [String]) -> Run {
        let capture = Console.Capture()
        let code = Console.$capture.withValue(capture) { runCommandLine(arguments) }
        return Run(code: code, out: capture.out, err: capture.err)
    }

    /// `compare` takes the words after `--` as the prompt, joined, as acpx's `scanCompareArgs`
    /// does — every word before them an agent (#250).
    @Test(.enabled(if: mockPythonAvailable))
    func comparesPromptIsTheWordsAfterTheSeparator() async throws {
        let agent = try #require(mockCommand())
        let run = await withIsolatedStore {
            Self.run(["--approve-all", "--format", "json", "compare", agent, agent, "--", "hello", "there"])
        }
        #expect(run.code == ExitCodes.success)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { ($0["final_message"] as? String)?.hasSuffix("You said: hello there") == true })
    }

    /// Two different prompt files are refused, as acpx's `resolvePromptFile` refuses them (#250).
    @Test func compareRefusesTwoPromptFiles() async {
        let run = await withIsolatedStore {
            Self.run(["compare", "--file", "a.txt", "--prompt-file", "b.txt", "codex", "claude"])
        }
        #expect(run.code == ExitCodes.usage)
        #expect(run.err.contains("Use only one prompt file flag: --file or --prompt-file"))
    }

    /// A conflicting permission mode fails first, as acpx checks it before the prompt, the agent
    /// and the session: a prompt for a session that doesn't exist, and a `compare` with no prompt
    /// (#252).
    @Test func aConflictingPermissionModeFailsFirst() async {
        let (prompt, compare) = await withIsolatedStore {
            (Self.run(["--approve-all", "--deny-all", "--agent", "/bin/true", "prompt", "hi"]),
             Self.run(["--approve-all", "--deny-all", "compare", "codex", "--"]))
        }
        for run in [prompt, compare] {
            #expect(run.code == ExitCodes.usage)
            #expect(run.err.contains("Use only one permission mode: --approve-all, --approve-reads, or --deny-all"))
        }
    }

    /// `sessions watch` takes a `-s` given to the agent command when it has no `--name` of its
    /// own, as acpx's `resolveSessionNameFromFlags` does (#252).
    @Test func sessionsWatchTakesTheAgentCommandsSession() async throws {
        let run = try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            try Data(#"{"agents": {"probe": {"command": "/bin/true"}}}"#.utf8).write(to: ACPXPaths.globalConfigPath)
            return Self.run(["probe", "-s", "backend", "sessions", "watch"])
        }
        #expect(run.code == ExitCodes.error)
        #expect(run.err.contains(#"No named session "backend""#))
    }
}
