@testable import ACPXCore
import Foundation
import Testing

/// A broken config is refused as acpx refuses it (#69): the same failure — JSON syntax
/// in V8's words, a non-object file, or the first invalid field in acpx's resolve order —
/// with the same message. Every case in the fixture was run through npm acpx 0.19.1
/// (`acpx config show`), its message recorded with the paths as `<global>`/`<project>`.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct ConfigErrorTests {
    private struct Case: Decodable {
        let global: String?
        let project: String?
        let exitCode: Int
        let error: String?
    }

    @Test func refusesWhatAcpxRefusesInItsWords() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-config-errors.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
        #expect(cases.count > 50)
        for testCase in cases {
            try await withIsolatedStore {
                let cwd = NSTemporaryDirectory() + "acpx-config-errors-\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
                if let global = testCase.global {
                    try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
                    try Data(global.utf8).write(to: ACPXPaths.globalConfigPath)
                }
                if let project = testCase.project {
                    try Data(project.utf8).write(to: ACPXPaths.projectConfigPath(cwd: cwd))
                }
                let label = "global: \(testCase.global.debugDescription) project: \(testCase.project.debugDescription)"
                do {
                    _ = try ConfigLoader.load(cwd: cwd)
                    #expect(testCase.error == nil, "\(label) loaded")
                } catch let error as ConfigError {
                    let message = error.message
                        .replacingOccurrences(of: ACPXPaths.globalConfigPath.path, with: "<global>")
                        .replacingOccurrences(of: ACPXPaths.projectConfigPath(cwd: cwd).path, with: "<project>")
                    #expect(message == testCase.error, "\(label)")
                }
            }
        }
    }

    /// A directory where the config file should be fails as Node's read fails.
    @Test func anUnreadableConfigFailsAsNodeReports() async throws {
        try await withIsolatedStore {
            let cwd = NSTemporaryDirectory() + "acpx-config-dir-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                at: ACPXPaths.projectConfigPath(cwd: cwd), withIntermediateDirectories: true)
            let error = #expect(throws: ConfigError.self) { try ConfigLoader.load(cwd: cwd) }
            #expect(error?.message == "EISDIR: illegal operation on a directory, read")
        }
    }

    /// The `argv` form resolves to the command line acpx shows for it; legacy `args`
    /// are quoted as `JSON.stringify` quotes them.
    @Test func agentEntriesResolveToAcpxsCommandLine() async throws {
        try await withIsolatedStore {
            let cwd = NSTemporaryDirectory() + "acpx-config-argv-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            try Data(#"""
                {"agents": {
                  "vec": {"argv": ["python3", "/tmp/agent.py", "a b", "--flag=x"]},
                  "old": {"command": "node", "args": ["/tmp/a.js", "say \"hi\""]},
                  "bare": {"command": " npx my-agent "}
                }}
                """#.utf8).write(to: ACPXPaths.projectConfigPath(cwd: cwd))
            let config = try ConfigLoader.load(cwd: cwd)
            #expect(config.agents["vec"] == #"python3 /tmp/agent.py "a b" --flag=x"#)
            #expect(config.agents["old"] == #"node "/tmp/a.js" "say \"hi\"""#)
            #expect(config.agents["bare"] == "npx my-agent")
        }
    }
}
