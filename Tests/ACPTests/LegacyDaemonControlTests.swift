import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A daemon started by an earlier build: its controls returned `true` (`setMode`,
/// `setModel`) or the agent's config options (`setConfigOption`), not
/// ``SessionControlResult``.
@MCPServer(name: "acpx")
actor LegacyControlDaemon {
    /// Set a session's mode.
    /// - Parameters:
    ///   - sessionId: the session.
    ///   - modeId: the mode.
    @MCPTool
    func setMode(sessionId: String, modeId: String) -> Bool { true }

    /// Set a session's model.
    /// - Parameters:
    ///   - sessionId: the session.
    ///   - modelId: the model.
    @MCPTool
    func setModel(sessionId: String, modelId: String) -> Bool { true }

    /// Set a session config option.
    /// - Parameters:
    ///   - sessionId: the session.
    ///   - configId: the option.
    ///   - value: its value.
    @MCPTool
    func setConfigOption(sessionId: String, configId: String, value: String) -> [JSONValue] {
        [.object(["id": .string(configId), "currentValue": .string(value)])]
    }
}

/// `acpxd` outlives the CLI: after an upgrade, the new `acpx` can still be talking to a
/// daemon from the build before. Its controls then go on working, and report no
/// `resumed`, which that daemon never told.
@Suite struct LegacyDaemonControlTests {
    @Test func controlsStillWorkWithADaemonFromBeforeResumed() async throws {
        let proxy = MCPServerProxy(config: .stdioHandles(server: LegacyControlDaemon()))
        try await proxy.connect()
        let client = ACPXDaemon.Client(proxy: proxy)

        let mode = try await client.setMode(sessionId: "s", modeId: "plan")
        #expect(!mode.resumed)
        #expect(mode.configOptions == nil)
        #expect(try await client.setModel(sessionId: "s", modelId: "opus").resumed == false)

        let option = try await client.setConfigOption(sessionId: "s", configId: "effort", value: "high")
        #expect(!option.resumed)
        #expect(option.configOptions == [.object(["id": .string("effort"), "currentValue": .string("high")])])
        await proxy.disconnect()
    }

    /// Today's shape still decodes as itself.
    @Test func theCurrentResultDecodesAsItIs() throws {
        let decoded = try JSONDecoder().decode(
            SessionControlResult.self, from: Data(#"{"resumed":true,"configOptions":[]}"#.utf8))
        #expect(decoded.resumed)
        #expect(decoded.configOptions == [])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionControlResult.self, from: Data(#""yes""#.utf8))
        }
    }
}
