@testable import ACPXCore
@testable import acpxd
import Foundation
import Testing

extension DaemonToolsTests {
    @Test(.enabled(if: mockPythonAvailable))
    func configuredMcpServersReachNewLoadAndFallbackNew() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            try FileManager.default.createDirectory(
                at: ACPXPaths.baseDir, withIntermediateDirectories: true)
            let config = #"""
                {"mcpServers":[
                  {"name":"stdio","command":"tool","args":["one"],
                   "env":[{"name":"TOKEN","value":"secret"}],"_meta":{"source":"test"}},
                  {"type":"http","name":"remote","url":"https://example.com/mcp",
                   "headers":[{"name":"Authorization","value":"Bearer token"}]},
                  {"type":"sse","name":"events","url":"https://example.com/sse"}
                ]}
                """#
            try config.write(to: ACPXPaths.globalConfigPath, atomically: true, encoding: .utf8)

            let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
            let loggedCommand = "/usr/bin/env MOCK_REQUEST_LOG='\(log.path)' \(command)"
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: loggedCommand, cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "ping")

            let requests = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n")
                .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
                .filter { ($0["method"] as? String) != "session/prompt" }
            #expect(requests.compactMap { $0["method"] as? String } == [
                "session/new", "session/load", "session/new"
            ])

            for request in requests {
                let params = try #require(request["params"] as? [String: Any])
                let servers = try #require(params["mcpServers"] as? [[String: Any]])
                #expect(servers.count == 3)
                #expect(servers[0]["type"] == nil)
                #expect(servers[0]["name"] as? String == "stdio")
                #expect(servers[0]["args"] as? [String] == ["one"])
                #expect((servers[0]["_meta"] as? [String: String])?["source"] == "test")
                #expect(servers[1]["type"] as? String == "http")
                #expect(servers[1]["url"] as? String == "https://example.com/mcp")
                #expect(servers[2]["type"] as? String == "sse")
                #expect(servers[2]["headers"] as? [[String: String]] == [])
            }
        }
    }
}
