@testable import ACPXCore
import Foundation
import Testing

/// acpx lists config-defined agents in config order (#47). Its merge is a JavaScript
/// object spread, `{...globalAgents, ...projectAgents}`: global names in file order,
/// then project-only ones in theirs, and a name in both keeps its global place.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct ConfigAgentOrderTests {
    private func project(global: String?, project: String?) throws -> String {
        let cwd = NSTemporaryDirectory() + "acpx-agent-order-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        if let global {
            try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            try global.write(to: ACPXPaths.globalConfigPath, atomically: true, encoding: .utf8)
        }
        if let project {
            try project.write(to: ACPXPaths.projectConfigPath(cwd: cwd), atomically: true, encoding: .utf8)
        }
        return cwd
    }

    @Test func agentsKeepConfigOrderAcrossBothFiles() async throws {
        try await withIsolatedStore {
            let cwd = try project(
                global: #"{"agents":{"zeta":{"command":"z"},"Alpha":{"command":"a"}}}"#,
                project: #"{"agents":{"mid":{"command":"m"},"alpha":{"command":"a2"}}}"#)
            let config = try ConfigLoader.load(cwd: cwd)
            #expect(config.agentOrder == ["zeta", "alpha", "mid"])
            // The project's value, in the global's place.
            #expect(config.agents["alpha"] == "a2")
        }
    }

    /// A file that starts with a byte-order mark is not JSON to `JSON.parse`, so acpx
    /// refuses it — and so does this (#69).
    @Test func aByteOrderMarkIsRefusedAsAcpxRefusesIt() async throws {
        try await withIsolatedStore {
            let cwd = try project(global: nil, project: "\u{FEFF}" + #"{"agents":{"zeta":{"command":"z"}}}"#)
            let error = #expect(throws: ConfigError.self) { try ConfigLoader.load(cwd: cwd) }
            let expected = #"Unexpected token '\#u{FEFF}', "\#u{FEFF}{"agents""... is not valid JSON"#
            #expect(error?.message.hasSuffix(expected) == true)
        }
    }

    @Test func noConfigNoAgents() async throws {
        try await withIsolatedStore {
            let config = try ConfigLoader.load(cwd: try project(global: nil, project: nil))
            #expect(config.agentOrder.isEmpty)
        }
    }

    /// `Object.entries` lists array-index names first, in numeric order; names are
    /// trimmed and lowercased, and one repeated after that keeps its first place.
    @Test func namesAreOrderedAsAJavaScriptObjectOrdersThem() async throws {
        try await withIsolatedStore {
            let numeric = try project(
                global: nil, project: #"{"agents":{"b":{"command":"b"},"2":{"command":"2"},"1":{"command":"1"}}}"#)
            #expect(try ConfigLoader.load(cwd: numeric).agentOrder == ["1", "2", "b"])
            let repeated = try project(
                global: nil,
                project: #"{"agents":{" Beta ":{"command":"x"},"beta":{"command":"y"},"gamma":{"command":"z"}}}"#)
            let config = try ConfigLoader.load(cwd: repeated)
            #expect(config.agentOrder == ["beta", "gamma"])
            #expect(config.agents["beta"] == "y")
        }
    }
}
