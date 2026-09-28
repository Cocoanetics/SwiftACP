@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP
import Testing

/// A session's record keeps the agent's capabilities as its `initialize` answer wrote them —
/// every member, in its order — as acpx records them when it creates the session, and again after
/// each turn that succeeds (`savePromptSuccess`, #119).
@Suite(.serialized, .agentLane) struct AgentCapabilitiesRecordTests {
    static let created = #"{"zeta":1,"promptCapabilities":{"image":true,"audio":false},"loadSession":true,"#
        + #""_meta":{"b":1,"a":2}}"#
    static let later = #"{"loadSession":true,"yak":2,"promptCapabilities":{"audio":false,"image":false}}"#

    /// The mock, answering `initialize` with the capabilities `file` holds when it starts.
    static func agent(capabilities file: URL) throws -> String {
        try "/usr/bin/env MOCK_CAPABILITIES_FILE='\(file.path)' " + #require(mockCommand())
    }

    /// `recordId`'s `agent_capabilities`, as its file has them.
    static func written(_ recordId: String) throws -> String? {
        let file = try Data(contentsOf: ACPXPaths.sessionRecordPath(recordId))
        return WireJSON(parsing: file)?["agent_capabilities"]?.stringified
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aNewSessionKeepsTheCapabilitiesAsSent() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capabilities = directory.appendingPathComponent("capabilities.json")
        try Self.created.write(to: capabilities, atomically: true, encoding: .utf8)
        try await withIsolatedStore {
            let record = try await SessionEngine.createSession(
                agentCommand: Self.agent(capabilities: capabilities), cwd: directory.path, name: nil,
                permission: .approveAll, authCredentials: [:], authPolicy: "skip")
            #expect(try Self.written(record.acpxRecordId) == Self.created)
        }
    }

    /// A turn that succeeds records what its agent answered `initialize` with, as sent — here, an
    /// agent that says something else than when the session was made.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aTurnThatSucceedsTakesTheCapabilitiesItWasAnswered() async throws {
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capabilities = directory.appendingPathComponent("capabilities.json")
        try Self.created.write(to: capabilities, atomically: true, encoding: .utf8)
        try await withIsolatedStore {
            let record = try await SessionEngine.createSession(
                agentCommand: Self.agent(capabilities: capabilities), cwd: directory.path, name: nil,
                permission: .approveAll, authCredentials: [:], authPolicy: "skip")
            try Self.later.write(to: capabilities, atomically: true, encoding: .utf8)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let session = Session(id: UUID())
            await session.setTransport(DaemonToolsTests.CallingClient())
            _ = try await session.work { _ in
                try await daemon.runPrompt(sessionId: record.acpxRecordId, text: "hi")
            }
            await daemon.releaseAll()
            #expect(try Self.written(record.acpxRecordId) == Self.later)
        }
    }
}
