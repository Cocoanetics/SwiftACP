#if os(macOS) || os(Linux)
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How an agent ends, as acpx's client sees it (#87): its exit named on the requests
/// it leaves waiting, a handshake it dies in reported with its stderr, and closing it
/// ending it — and what it started — whatever it ignores. Each message is acpx 0.19.1's
/// for the same `exit-agent.py`.
@Suite struct AgentEndTests {
    static func command(_ environment: String) throws -> String {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/exit-agent.py")
        return "/usr/bin/env \(environment) '\(python)' '\(fixture.path)'"
    }

    static func launch(_ environment: String, onRawWire: RawWireTap.Observer? = nil) async throws -> ACPAgent {
        try await ACPAgent.launch(
            agent: command(environment), cwd: NSTemporaryDirectory(), permission: .approveAll,
            inheritStderr: false, onRawWire: onRawWire)
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    @Test(.enabled(if: mockPythonAvailable))
    func anAgentExitingMidTurnSaysHowItEnded() async throws {
        let agent = try await Self.launch("EXIT_AGENT_ON=prompt EXIT_AGENT_CODE=3")
        let session = try await agent.newSession()
        let error = await #expect(throws: AgentDisconnectedError.self) {
            _ = try await session.prompt([.text("hi")])
        }
        #expect(error == AgentDisconnectedError(reason: .processExit, exitCode: 3, signal: nil))
        #expect(error?.localizedDescription
            == "ACP agent disconnected during request (process_exit, exit=3, signal=null)")
        let lifecycle = try #require(agent.lifecycle)
        #expect(!lifecycle.running)
        #expect(lifecycle.lastExit?.reason == .processExit)
        #expect(lifecycle.lastExit?.exitCode == 3)
        #expect(lifecycle.lastExit?.unexpectedDuringPrompt == true)
        await agent.close()
    }

    @Test(.enabled(if: mockPythonAvailable))
    func anAgentKilledMidTurnNamesTheSignal() async throws {
        let agent = try await Self.launch("EXIT_AGENT_ON=prompt EXIT_AGENT_SIGNAL=KILL")
        let session = try await agent.newSession()
        let error = await #expect(throws: AgentDisconnectedError.self) {
            _ = try await session.prompt([.text("hi")])
        }
        #expect(error?.localizedDescription
            == "ACP agent disconnected during request (process_exit, exit=null, signal=SIGKILL)")
        await agent.close()
    }

    /// Closing an agent mid-turn ends it as the client's doing, not unexpectedly: acpx's
    /// `close()` marks its client closing before anything of the end is recorded (#113
    /// review).
    @Test(.enabled(if: mockPythonAvailable))
    func closingAnAgentMidTurnIsNoUnexpectedEnd() async throws {
        let (streamed, streaming) = AsyncStream<Void>.makeStream()
        let agent = try await Self.launch("EXIT_AGENT_HOLD=1") { direction, body in
            if direction == .inbound, String(decoding: body, as: UTF8.self).contains("partial ") { streaming.yield() }
        }
        let session = try await agent.newSession()
        let turn = Task { try await session.prompt([.text("hi")]) }
        var updates = streamed.makeAsyncIterator()
        _ = await updates.next()
        await agent.close()
        _ = await turn.result
        let exit = try #require(agent.lifecycle?.lastExit)
        #expect(exit.reason == .connectionClose)
        #expect(!exit.unexpectedDuringPrompt)
    }

    /// acpx's `AgentStartupError`: the exit, then the agent's stderr with its runs of
    /// whitespace made one space.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentExitingInItsHandshakeSaysWhy() async throws {
        let error = await #expect(throws: AgentStartupError.self) {
            _ = try await Self.launch("EXIT_AGENT_ON=initialize EXIT_AGENT_STDERR='boom\n  second   line\n'")
        }
        #expect(error?.localizedDescription
            == "ACP agent exited before initialize completed (exit=3, signal=null): boom second line")
    }

    /// What the agent wrote before it exited is all read before its end is reported.
    @Test(.enabled(if: mockPythonAvailable))
    func anAnswerWrittenBeforeTheExitArrives() async throws {
        let agent = try await Self.launch("EXIT_AGENT_ANSWER_THEN_EXIT=1")
        let session = try await agent.newSession()
        let outcome = try await session.run("hi")
        #expect(outcome.stopReason == .endTurn)
        await agent.connection.waitUntilClosed()
        let exit = try #require(agent.lifecycle?.lastExit)
        #expect(exit.reason == .processExit)
        #expect(exit.exitCode == 0)
        #expect(!exit.unexpectedDuringPrompt)
        await agent.close()
    }

    /// Its stdout closing while it runs on is put down to the pipe.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentClosingItsStdoutIsPutDownToThePipe() async throws {
        let agent = try await Self.launch("EXIT_AGENT_CLOSE_STDOUT=1")
        let session = try await agent.newSession()
        let error = await #expect(throws: AgentDisconnectedError.self) {
            _ = try await session.prompt([.text("hi")])
        }
        #expect(error == AgentDisconnectedError(reason: .pipeClose, exitCode: nil, signal: nil))
        // It is ended with its connection, closed or not (#113 review).
        let transport = try #require(agent.transport as? AgentProcessTransport)
        #expect(await transport.waitForExit(timeout: .seconds(5)))
        await agent.close()
    }

    /// The transport ends such an agent itself, whoever reads it — not only once a
    /// JSON-RPC peer, seeing the end, closes it (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func theTransportEndsAnAgentWhoseStdoutClosed() async throws {
        let launch = try AgentRegistry.launch(
            for: Self.command("EXIT_AGENT_CLOSE_STDOUT=1"), cwd: NSTemporaryDirectory(),
            environment: nil, inheritStderr: false)
        let transport = try AgentProcessTransport.start(
            launch, agentCommand: "exit-agent", maxMessageBytes: nil, tap: RawWireTap())
        try transport.send(.request(id: 1, method: "session/prompt", params: .object([
            "sessionId": .string("exit-session"), "prompt": .array([])
        ])))
        var ending: Error?
        do {
            for try await _ in transport.makeInboundStream() {}
        } catch {
            ending = error
        }
        #expect(ending as? AgentDisconnectedError
            == AgentDisconnectedError(reason: .pipeClose, exitCode: nil, signal: nil))
        #expect(await transport.waitForExit(timeout: .seconds(5)))
        await transport.terminate()
    }

    /// Nothing keeps a transport once its agent is closed: its writer's failure hook holds
    /// it weakly (#113 review). Letting go has no signal to wait on, so the check gives
    /// the reader thread, which ends last, a moment to finish.
    @Test(.enabled(if: mockPythonAvailable))
    func aClosedTransportIsLetGo() async throws {
        weak var released: AgentProcessTransport?
        do {
            let launch = try AgentRegistry.launch(
                for: Self.command(""), cwd: NSTemporaryDirectory(), environment: nil, inheritStderr: false)
            let transport = try AgentProcessTransport.start(
                launch, agentCommand: "exit-agent", maxMessageBytes: nil, tap: RawWireTap())
            released = transport
            transport.close()
            await transport.terminate()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while released != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
    }

    /// A handshake the agent refuses fails with its error, not as a startup failure: it
    /// is still running when it answers, and exits only once it is closed (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func aHandshakeTheAgentRefusesKeepsItsError() async throws {
        let error = await #expect(throws: JSONRPCErrorBody.self) {
            _ = try await Self.launch("EXIT_AGENT_INIT_ERROR=1")
        }
        #expect(error?.message == "init refused")
    }

    /// So does one the client gives up on: no credential for the agent's sign-in, under
    /// the `fail` policy.
    @Test(.enabled(if: mockPythonAvailable))
    func aSignInRefusedByPolicyKeepsItsError() async throws {
        await #expect(throws: AuthPolicyError.self) {
            _ = try await ACPAgent.launch(
                agent: Self.command("EXIT_AGENT_AUTH=1"), cwd: NSTemporaryDirectory(), permission: .approveAll,
                authPolicy: "fail", inheritStderr: false)
        }
    }

    /// A message the agent can no longer be sent — it closed its stdin, but runs on —
    /// ends the connection, rather than leaving its request waiting; nor does the write
    /// raise `SIGPIPE` here.
    @Test(.enabled(if: mockPythonAvailable))
    func anAgentThatClosedItsStdinEndsTheConnection() async throws {
        let agent = try await Self.launch("EXIT_AGENT_CLOSE_STDIN=1")
        let session = try await agent.newSession()
        let error = await #expect(throws: AgentDisconnectedError.self) {
            _ = try await session.prompt([.text("hi")])
        }
        #expect(error == AgentDisconnectedError(reason: .connectionClose, exitCode: nil, signal: nil))
        await agent.close()
    }

    /// acpx reads only JSON objects off the agent's stdout: other JSON values — a batch
    /// among them — are dropped unseen, a stray object is seen but goes nowhere, and a
    /// line that is no JSON is skipped.
    @Test(.enabled(if: mockPythonAvailable))
    func onlyObjectsAreReadOffTheAgentsOutput() async throws {
        let wire = Lines()
        let agent = try await Self.launch("EXIT_AGENT_STRAY=1") { direction, body in
            if direction == .inbound { wire.append(String(decoding: body, as: UTF8.self)) }
        }
        let session = try await agent.newSession()
        let chunks = Lines()
        let outcome = try await session.run("hi") { update in
            if case .agentMessageChunk(let block) = update, let text = block.text { chunks.append(text) }
        }
        #expect(outcome.stopReason == .endTurn)
        #expect(chunks.all == ["partial "])
        #expect(wire.all.contains(#"{"stray":true}"#))
        #expect(!wire.all.contains { $0 == "42" || $0 == #""x""# || $0 == "null" || $0.hasPrefix("[") })
        await agent.close()
    }

    /// acpx's `cleanupAgentProcess`: an agent that ignores its stdin's end and `SIGTERM`
    /// is killed, and closing it is what its end is put down to.
    @Test(.enabled(if: mockPythonAvailable))
    func closingEndsAnAgentThatIgnoresItsStdinAndSIGTERM() async throws {
        let agent = try await Self.launch("EXIT_AGENT_STUBBORN=1")
        let pid = try #require(agent.lifecycle?.pid)
        await agent.close()
        #expect(!Self.isRunning(pid))
        let lifecycle = try #require(agent.lifecycle)
        #expect(!lifecycle.running)
        #expect(lifecycle.lastExit?.reason == .connectionClose)
        #expect(lifecycle.lastExit?.exitCode == nil)
    }

    /// What the agent started goes with it, although it outlives the agent and is
    /// handed to `init` on the way.
    @Test(.enabled(if: mockPythonAvailable))
    func closingEndsWhatTheAgentStarted() async throws {
        let pidFile = NSTemporaryDirectory() + "exit-agent-child-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let agent = try await Self.launch("EXIT_AGENT_CHILD='\(pidFile)'")
        let child = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)))
        #expect(Self.isRunning(child))
        await agent.close()
        #expect(!Self.isRunning(child))
    }

    /// So is what it starts when it opens a session, though the agent exits first and it
    /// is handed to `init`: acpx notes the agent's processes again once a session is open
    /// (#113 review).
    @Test(.enabled(if: mockPythonAvailable))
    func whatTheAgentStartsForASessionEndsWithIt() async throws {
        let pidFile = NSTemporaryDirectory() + "exit-agent-child-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let agent = try await Self.launch(
            "EXIT_AGENT_CHILD='\(pidFile)' EXIT_AGENT_CHILD_AT=session/new EXIT_AGENT_ON=prompt")
        let session = try await agent.newSession()
        let child = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)))
        #expect(Self.isRunning(child))
        _ = try? await session.prompt([.text("hi")])
        await agent.close()
        #expect(!Self.isRunning(child))
    }

    /// A line longer than `ACPX_MAX_ACP_MESSAGE_BYTES` fails what waits with acpx's
    /// error and ends the connection; a line of exactly the limit is read.
    @Test(.enabled(if: mockPythonAvailable))
    func aLineLongerThanTheLimitEndsTheConnection() async throws {
        for (bytes, fails) in [(200, false), (201, true)] {
            let launch = try AgentRegistry.launch(
                for: Self.command("EXIT_AGENT_LINE_BYTES=\(bytes)"), cwd: NSTemporaryDirectory(),
                environment: nil, inheritStderr: false)
            let transport = try AgentProcessTransport.start(
                launch, agentCommand: "exit-agent", maxMessageBytes: 200, tap: RawWireTap())
            let connection = ACPAgentConnection(transport: transport)
            await connection.start()
            if fails {
                let error = await #expect(throws: AcpMessageLimitError.self) {
                    _ = try await connection.initialize(capabilities: .acpx, clientInfo: .acpx)
                }
                #expect(error?.localizedDescription == """
                    ACP message exceeded ACPX_MAX_ACP_MESSAGE_BYTES (200 bytes). \
                    Increase the limit or set it to 0 for unlimited input.
                    """)
                #expect(transport.lifecycle.lastExit?.reason == .connectionClose)
            } else {
                _ = try await connection.initialize(capabilities: .acpx, clientInfo: .acpx)
            }
            await connection.close()
            await transport.terminate()
            #expect(!transport.lifecycle.running)
        }
    }
}

/// Lines collected from callbacks on other threads.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var all: [String] { lock.withLock { lines } }
}
#endif
