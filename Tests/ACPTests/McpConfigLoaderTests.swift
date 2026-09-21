@testable import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// `--mcp-config <path>` (npm acpx parity): an explicit file's `mcpServers` replaces
/// the project/global ones for the invocation, resolves relative to the cwd, and
/// becomes the session's own server set (`sessionMcpServers`) for records created
/// under it.
///
/// Serialized because the tests redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct McpConfigLoaderTests {
    @Test func explicitFileReplacesConfigFileServers() async throws {
        try await withIsolatedStore {
            let cwd = try makeProjectDir()
            try writeGlobalConfig(#"{"mcpServers":[{"name":"global","command":"g"}]}"#)
            try #"{"mcpServers":[{"name":"project","command":"p"}]}"#
                .write(to: ACPXPaths.projectConfigPath(cwd: cwd), atomically: true, encoding: .utf8)
            let explicit = cwd + "/job-mcp.json"
            try #"{"mcpServers":[{"type":"http","name":"job","url":"https://example.com/mcp"}]}"#
                .write(toFile: explicit, atomically: true, encoding: .utf8)

            // Without the flag: project replaces global, and the session has no own set.
            let plain = try ConfigLoader.load(cwd: cwd)
            #expect(plain.mcpServers.map(\.name) == ["project"])
            #expect(plain.mcpConfigPath == nil)
            #expect(plain.sessionMcpServers == nil)

            // With it: the file replaces both, and its servers are the session's own.
            let config = try ConfigLoader.load(cwd: cwd, mcpConfigPath: explicit)
            #expect(config.mcpServers.map(\.name) == ["job"])
            #expect(config.mcpConfigPath == explicit)
            #expect(config.sessionMcpServers == [
                McpServerConfig(type: "http", name: "job", url: "https://example.com/mcp")
            ])
            // The rest of the config is untouched by the flag.
            #expect(config.hasGlobalConfig && config.hasProjectConfig)
        }
    }

    @Test func relativePathResolvesFromCwd() async throws {
        try await withIsolatedStore {
            let cwd = try makeProjectDir()
            try FileManager.default.createDirectory(
                atPath: cwd + "/run", withIntermediateDirectories: true)
            try #"{"mcpServers":[{"name":"rel","command":"r"}]}"#
                .write(toFile: cwd + "/run/mcp.json", atomically: true, encoding: .utf8)

            let config = try ConfigLoader.load(cwd: cwd, mcpConfigPath: "run/../run/mcp.json")
            #expect(config.mcpServers.map(\.name) == ["rel"])
            #expect(config.mcpConfigPath == cwd + "/run/mcp.json")
        }
    }

    @Test func explicitFileMustExistAndCarryTheArray() async throws {
        try await withIsolatedStore {
            let cwd = try makeProjectDir()
            let missing = cwd + "/nope.json"
            #expect(throws: ConfigError.self) {
                try ConfigLoader.load(cwd: cwd, mcpConfigPath: missing)
            }
            do {
                _ = try ConfigLoader.load(cwd: cwd, mcpConfigPath: missing)
            } catch let error as ConfigError {
                // npm acpx's parseMcpServers wording.
                #expect(error.message == "Invalid mcpServers in \(missing): expected array")
            }

            let noArray = cwd + "/other.json"
            try #"{"defaultAgent":"codex"}"#.write(toFile: noArray, atomically: true, encoding: .utf8)
            #expect(throws: ConfigError.self) {
                try ConfigLoader.load(cwd: cwd, mcpConfigPath: noArray)
            }

            // An explicitly empty array is valid and detaches every server.
            let empty = cwd + "/empty.json"
            try #"{"mcpServers":[]}"#.write(toFile: empty, atomically: true, encoding: .utf8)
            let config = try ConfigLoader.load(cwd: cwd, mcpConfigPath: empty)
            #expect(config.mcpServers.isEmpty)
            #expect(config.sessionMcpServers == [])
        }
    }

    @Test func explicitFileEntriesAreValidatedLikeConfigEntries() async throws {
        try await withIsolatedStore {
            let cwd = try makeProjectDir()
            let bad = cwd + "/bad.json"
            try #"{"mcpServers":[{"name":"broken"}]}"#.write(toFile: bad, atomically: true, encoding: .utf8)
            // Loading succeeds (the shape is fine); normalizing for the wire rejects it.
            let config = try ConfigLoader.load(cwd: cwd, mcpConfigPath: bad)
            #expect(throws: ConfigError.self) { try config.mcpServerSpecs() }
        }
    }

    // MARK: - Helpers

    private func makeProjectDir() throws -> String {
        let dir = ACPXPaths.baseDir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func writeGlobalConfig(_ json: String) throws {
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        try json.write(to: ACPXPaths.globalConfigPath, atomically: true, encoding: .utf8)
    }
}
