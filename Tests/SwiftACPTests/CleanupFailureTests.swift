#if os(macOS) || os(Linux) || os(Windows)
@testable import SwiftACP
import Foundation
import JSONRPCPeer
import Testing

/// A terminal cleanup that fails is said where acpx says it (#281): the terminals' shutdown
/// throws once every release was tried — acpx's "Terminal shutdown failed" — and closing the agent
/// throws it on after retiring everything else, as "ACP client cleanup failed". Only a Windows
/// terminal whose processes outlive their cleanup fails for real; a handler stands in for it.
@Suite(.timeLimit(.minutes(1)))
struct CleanupFailureTests {
    struct Unfinished: Error {}

    /// A terminal handler whose shutdown fails, counting its shutdowns.
    actor FailingTerminals: ACPTerminalHandler {
        private(set) var shutdowns = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func createTerminal(_ request: CreateTerminalRequest) throws -> CreateTerminalResponse {
            throw CancellationError()
        }

        func terminalOutput(_ request: TerminalOutputRequest) throws -> TerminalOutputResponse {
            throw TerminalError.unknownTerminal(request.terminalId)
        }

        func waitForTerminalExit(_ request: WaitForTerminalExitRequest) throws -> WaitForTerminalExitResponse {
            throw TerminalError.unknownTerminal(request.terminalId)
        }

        func killTerminal(_ request: KillTerminalRequest) throws -> KillTerminalResponse {
            throw TerminalError.unknownTerminal(request.terminalId)
        }

        func releaseTerminal(_ request: ReleaseTerminalRequest) -> ReleaseTerminalResponse {
            ReleaseTerminalResponse()
        }

        func shutdown() throws {
            shutdowns += 1
            waiters.forEach { $0.resume() }
            waiters = []
            throw TerminalShutdownFailed(failures: [Unfinished()])
        }

        /// Suspend until the first ``shutdown()``.
        func waitForShutdown() async {
            if shutdowns > 0 { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// An agent over a loopback, initialized; the agent's end of it; and the task serving it.
    struct Connected {
        let agent: ACPAgent
        let serverTransport: LoopbackTransport
        let server: Task<Void, Error>
    }

    /// An agent over a loopback, initialized, its terminals served by `terminals`.
    private func agent(terminals: FailingTerminals) async throws -> Connected {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(
            handler: TerminalRoutingTests.ScriptedAgent { _ in "" }, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let connection = ACPAgentConnection(transport: clientTransport)
        await connection.setTerminalHandler(terminals)
        await connection.start()
        let info = try await connection.initialize(capabilities: .acpxWithTerminals, clientInfo: .acpx)
        let agent = ACPAgent(
            name: "stand-in", cwd: "/", connection: connection, transport: clientTransport, rawWire: RawWireTap(),
            initializeResult: info, terminals: terminals)
        return Connected(agent: agent, serverTransport: serverTransport, server: serverTask)
    }

    /// Closing throws the terminals' failure once the rest is retired: the connection closed.
    @Test func closingSaysTheTerminalsFailedOnceTheRestIsRetired() async throws {
        let terminals = FailingTerminals()
        let connected = try await agent(terminals: terminals)
        let agent = connected.agent
        defer { connected.server.cancel() }

        let error = await #expect(throws: ACPClientCleanupFailed.self) { try await agent.close() }

        #expect(error?.localizedDescription == "ACP client cleanup failed")
        let cause = try #require(error?.cause as? TerminalShutdownFailed)
        #expect(cause.localizedDescription == "Terminal shutdown failed")
        #expect(cause.failures.count == 1 && cause.failures.first is Unfinished)
        #expect(await agent.connection.isClosed)
        #expect(await terminals.shutdowns == 1)
    }

    /// The terminals are shut down once, and every caller hears how it went — one that comes
    /// after too.
    @Test func everyCallerOfTheShutdownHearsHowItWent() async throws {
        let terminals = FailingTerminals()
        let connected = try await agent(terminals: terminals)
        let agent = connected.agent
        defer { connected.server.cancel() }
        let connection = agent.connection

        let first = Task { try await connection.shutDownTerminals() }
        let second = Task { try await connection.shutDownTerminals() }
        await #expect(throws: TerminalShutdownFailed.self) { try await first.value }
        await #expect(throws: TerminalShutdownFailed.self) { try await second.value }
        await #expect(throws: TerminalShutdownFailed.self) { try await connection.shutDownTerminals() }
        #expect(await terminals.shutdowns == 1)
        try? await agent.close()
    }

    /// A connection that ended by itself shut its terminals down then: closing the agent after
    /// still says how that went.
    @Test func aConnectionThatEndedByItselfStillSaysSoOnClose() async throws {
        let terminals = FailingTerminals()
        let connected = try await agent(terminals: terminals)
        let agent = connected.agent
        defer { connected.server.cancel() }

        connected.serverTransport.close()
        await agent.connection.waitUntilClosed()
        await terminals.waitForShutdown()

        await #expect(throws: ACPClientCleanupFailed.self) { try await agent.close() }
        #expect(await terminals.shutdowns == 1)
    }
}
#endif
