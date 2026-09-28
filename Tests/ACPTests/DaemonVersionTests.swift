@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
@testable import SwiftACP
import SwiftMCP
import Testing

/// acpxd reports its version, and acpx works only through a daemon reporting its own (#162).
@Suite(.serialized, .agentLane) struct DaemonVersionTests {
    private static func daemon() -> ACPXDaemon {
        ACPXDaemon(backend: ACPXDaemonBackend(inheritAgentStderr: false))
    }

    /// The pinned fingerprint is that of the daemon's tools: change a tool, and this says what to
    /// pin in its place.
    @Test func theVersionFollowsTheDaemonsTools() async {
        let fingerprint = ACPXDaemon.interfaceFingerprint(of: await Self.daemon().mcpToolMetadata.convertedToTools())
        #expect(
            fingerprint == ACPXDaemon.interfaceFingerprint,
            "The daemon's tools changed: set ACPXDaemon.interfaceFingerprint to \"\(fingerprint)\".")
    }

    /// What a tool says of itself leaves the fingerprint as it is; what it takes does not — nor a
    /// parameter that happens to be named `description`.
    @Test func onlyWhatAToolTakesOrReturnsChangesTheFingerprint() throws {
        func fingerprint(_ description: String, _ parameter: String, _ type: String) throws -> String {
            let json = #"[{"name":"t","description":"\#(description)","inputSchema":{"type":"object","#
                + #""description":"\#(description)","properties":{"\#(parameter)":{"type":"\#(type)","#
                + #""description":"\#(description)"}}}}]"#
            return ACPXDaemon.interfaceFingerprint(of: try JSONDecoder().decode([MCPTool].self, from: Data(json.utf8)))
        }
        let original = try fingerprint("one", "description", "string")
        #expect(try fingerprint("another", "description", "string") == original)
        #expect(try fingerprint("one", "description", "integer") != original)
        #expect(try fingerprint("one", "summary", "string") != original)
    }

    /// The daemon reports its version in MCP's `serverInfo`: SwiftACP's, and its tools'.
    @Test func theDaemonReportsItsVersion() async throws {
        let proxy = MCPServerProxy(config: .stdioHandles(server: Self.daemon()))
        try await proxy.connect()
        #expect(await proxy.serverVersion == ACPXDaemon.version)
        #expect(ACPXDaemon.version == "\(ACPVersion.current)+\(ACPXDaemon.interfaceFingerprint)")
        await proxy.disconnect()
    }

    /// A daemon of another version is not worked through: the CLI is told why and how to restart
    /// it, and starts no other in its place, which the one holding the lock would turn away.
    @Test func aDaemonOfAnotherVersionIsRefused() async throws {
        let other = DaemonOfAnotherBuild()
        let refusal = await #expect(throws: DaemonClient.DaemonVersionMismatch.self) {
            try await DaemonClient.$standIn.withValue(.stdioHandles(server: other)) {
                _ = try await DaemonClient.connect(spawnIfNeeded: true)
            }
        }
        #expect(refusal?.daemonVersion == "1.0")
        #expect(refusal?.localizedDescription == "acpxd is version 1.0, but this acpx is version "
            + "\(ACPXDaemon.version); the request was not run. Restart the daemon: stop it (stopping it, or quit "
            + "the app that runs it), and the next command starts this acpx's own. Its sessions are kept.")
        #expect(DaemonClient.DaemonVersionMismatch(daemonVersion: "1.0", pid: 42).localizedDescription
            .contains("acpxd (pid 42) is version 1.0") == true)
    }

    /// A control through a daemon of another version fails as acpx reports a failure — here in
    /// JSON — and never reaches that daemon.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlThroughADaemonOfAnotherVersionIsNotRun() async throws {
        let agent = try #require(mockCommand())
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            _ = try await SessionEngine.createSession(
                agentCommand: agent, cwd: directory.path, name: nil, permission: .approveAll, authCredentials: [:],
                authPolicy: "skip")
            let other = DaemonOfAnotherBuild()
            let capture = Console.Capture()
            let arguments = ["--agent", agent, "--cwd", directory.path, "--format", "json", "set-mode", "plan"]
            let code: Int32 = await onThreadOfItsOwn {
                DaemonClient.$standIn.withValue(.stdioHandles(server: other)) {
                    Console.$capture.withValue(capture) { runCommandLine(arguments) }
                }
            }
            #expect(code == 1)
            #expect(capture.out.contains(#""data":{"acpxCode":"RUNTIME","detailCode":"DAEMON_VERSION_MISMATCH","#
                + #""origin":"cli","retryable":false"#), "\(capture.out)")
            #expect(await other.modesSet.isEmpty)
        }
    }
}

extension DaemonVersionTests {
    /// `sessions close` through a daemon of another version is refused too, the record left
    /// open: that daemon would go on holding an agent the closed record no longer names.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCloseThroughADaemonOfAnotherVersionIsRefused() async throws {
        let agent = try #require(mockCommand())
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let created = try await SessionEngine.createSession(
                agentCommand: agent, cwd: directory.path, name: nil, permission: .approveAll, authCredentials: [:],
                authPolicy: "skip")
            let capture = Console.Capture()
            let code: Int32 = await onThreadOfItsOwn {
                DaemonClient.$standIn.withValue(.stdioHandles(server: DaemonOfAnotherBuild())) {
                    Console.$capture.withValue(capture) {
                        runCommandLine(["--agent", agent, "--cwd", directory.path, "sessions", "close"])
                    }
                }
            }
            #expect(code == 1)
            #expect(capture.err.hasPrefix("acpxd is version 1.0, but this acpx is version"), "\(capture.err)")
            #expect(try #require(SessionStore.loadRecord(created.acpxRecordId)).closed != true)
        }
    }
}

/// An acpxd of another build: its version, the macro's `1.0`, is not this CLI's.
@MCPServer(name: "acpx")
actor DaemonOfAnotherBuild {
    private(set) var modesSet: [String] = []

    /// Set a session's mode.
    /// - Parameters:
    ///   - sessionId: the session.
    ///   - modeId: the mode.
    @MCPTool
    func setMode(sessionId: String, modeId: String) -> Bool {
        modesSet.append(modeId)
        return true
    }
}
