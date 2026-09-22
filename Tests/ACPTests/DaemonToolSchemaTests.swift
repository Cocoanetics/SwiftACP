@testable import acpxd
import JSONFoundation
import SwiftACP
import Testing

/// The daemon's advertised tool schemas for the per-session MCP server surface.
struct DaemonToolSchemaTests {
    /// `mcpServers` is advertised as a real object schema (the config-file entry
    /// shape, `name` required), not an opaque string — an MCP client must be able
    /// to construct entries from the tool listing alone.
    @Test func newSessionAdvertisesMcpServersAsObjectSchema() async throws {
        let daemon = ACPXDaemon(backend: ACPXDaemonBackend(inheritAgentStderr: false))
        let tools = await daemon.mcpToolMetadata
        let newSession = try #require(tools.first { $0.functionMetadata.name == "newSession" })
        let parameter = try #require(newSession.functionMetadata.parameters.first { $0.name == "mcpServers" })
        #expect(!parameter.isRequired)
        let schema = try JSONValue(encoding: parameter.schema)
        #expect(schema["type"] == .string("array"))
        let items = try #require(schema["items"])
        #expect(items["type"] == .string("object"))
        #expect(items["required"] == .array([.string("name")]))
        let properties = try #require(items["properties"])
        for key in ["type", "name", "command", "args", "env", "url", "headers", "_meta"] {
            #expect(properties[key] != nil, "missing \(key)")
        }
        #expect(properties["env"]?["items"]?["required"] == .array([.string("name"), .string("value")]))
        #expect(properties["_meta"]?["type"] == .string("object"))

        let setter = try #require(tools.first { $0.functionMetadata.name == "setSessionMcpServers" })
        let servers = try #require(setter.functionMetadata.parameters.first { $0.name == "mcpServers" })
        #expect(servers.isRequired)
        #expect(try JSONValue(encoding: servers.schema)["items"]?["type"] == .string("object"))
    }
}
