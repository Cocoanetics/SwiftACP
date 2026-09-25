@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
@testable import SwiftACP
import Testing

/// What `exec` shows of a prompt attempt, and of the pause before another: everything
/// the agent sent in it, in wire order, before its failure — however late the connection
/// hands it on — and nothing after (#106).
struct ExecPromptEventsTests {
    /// An attempt cut off by the deadline shows everything the agent sent before it,
    /// before the timeout is thrown — and nothing after: its events end with it, though
    /// the prompt is still out. The output here is slower than the agent's burst.
    @Test(.enabled(if: mockPythonAvailable))
    func aTimedOutAttemptShowsItsEventsBeforeItsFailure() async throws {
        let agent = try await Self.launchFixture(mode: "burst-then-hang")
        let written = Written()
        let renderer = OutputRenderer(
            options: RenderOptions(format: .text), out: { written.append($0) }, err: { _ in }, color: false)
        renderer.beforeRenderingEvent = { try? await Task.sleep(for: .milliseconds(20)) }
        do {
            let response = try await agent.connection.newSession(
                NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
            let session = ACPSession(id: response.sessionId, agent: agent)
            let policy = ExecCommand.PromptPolicy(timeoutMilliseconds: 200, retries: 0, quiet: false)
            await #expect(throws: TimeoutError(milliseconds: 200)) {
                _ = try await ExecCommand.runPrompt(
                    [.text("hi")], on: session, policy: policy, renderer: renderer, sideEffects: PromptSideEffects())
            }
        } catch {
            await agent.close()
            throw error
        }
        let atTheFailure = written.value
        await agent.close()
        #expect(atTheFailure.contains("u0 ") && atTheFailure.contains("u19 "), "\(atTheFailure)")
        #expect(written.value == atTheFailure)
    }

    /// An update the connection read before the deadline is shown however late it is
    /// handed on: the attempt's events end only once everything read of the agent has
    /// been. Here its handling is held until the attempt's end waits for it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anUpdateReadBeforeTheDeadlineIsShownThoughHandedOnLate() async throws {
        let agent = try await Self.launchFixture(mode: "burst-then-hang")
        let written = Written()
        let renderer = OutputRenderer(
            options: RenderOptions(format: .text), out: { written.append($0) }, err: { _ in }, color: false)
        let (released, release) = AsyncStream<Void>.makeStream()
        await agent.connection.setBeforeHandlingUpdate { for await _ in released { break } }
        await agent.connection.setOnUpdateWait { _ in release.finish() }
        do {
            let response = try await agent.connection.newSession(
                NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
            let session = ACPSession(id: response.sessionId, agent: agent)
            let policy = ExecCommand.PromptPolicy(timeoutMilliseconds: 200, retries: 0, quiet: false)
            await #expect(throws: TimeoutError(milliseconds: 200)) {
                _ = try await ExecCommand.runPrompt(
                    [.text("hi")], on: session, policy: policy, renderer: renderer, sideEffects: PromptSideEffects())
            }
        } catch {
            release.finish()
            await agent.close()
            throw error
        }
        let shown = written.value
        release.finish()
        await agent.close()
        #expect(shown.hasPrefix("u0 "), "\(shown)")
    }

    /// An update that calls the retry off is shown however late the connection hands it
    /// on: the pause's events end only once everything the connection read of the agent
    /// has been handed on. Here its handling is held until the pause's end waits for it.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anUpdateThatCallsTheRetryOffIsShownThoughHandedOnLate() async throws {
        let agent = try await Self.launchFixture(mode: "fail-then-update")
        let written = Written()
        let renderer = OutputRenderer(
            options: RenderOptions(format: .text), out: { written.append($0) }, err: { _ in }, color: false)
        let (released, release) = AsyncStream<Void>.makeStream()
        await agent.connection.setBeforeHandlingUpdate { for await _ in released { break } }
        await agent.connection.setOnUpdateWait { _ in release.finish() }
        let sideEffects = PromptSideEffects()
        await agent.connection.setWireMessageObserver { sideEffects.observe($0, $1) }
        do {
            let response = try await agent.connection.newSession(
                NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
            let session = ACPSession(id: response.sessionId, agent: agent)
            let policy = ExecCommand.PromptPolicy(timeoutMilliseconds: nil, retries: 1, quiet: true)
            await #expect(throws: JSONRPCErrorBody.self) {
                _ = try await ExecCommand.runPrompt(
                    [.text("hi")], on: session, policy: policy, renderer: renderer, sideEffects: sideEffects)
            }
        } catch {
            release.finish()
            await agent.close()
            throw error
        }
        let shown = written.value
        release.finish()
        await agent.close()
        #expect(shown.hasSuffix("[error] RUNTIME: model overloaded\nlate "), "\(shown)")
    }

    /// The fixture agent in `mode`, launched.
    private static func launchFixture(mode: String) async throws -> ACPAgent {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retry-agent.py")
        var environment = ProcessInfo.processInfo.environment
        environment["RETRY_AGENT_MODE"] = mode
        return try await ACPAgent.launch(
            agent: "'\(python)' '\(fixture.path)'", cwd: NSTemporaryDirectory(), permission: .approveAll,
            environment: environment, inheritStderr: false)
    }

    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        var value: String { lock.withLock { text } }
        func append(_ more: String) { lock.withLock { text += more } }
    }

    /// A failed turn hands on every update the agent sent before failing, and only then
    /// throws — so what reports the failure comes after them.
    @Test(.enabled(if: mockPythonAvailable))
    func aFailedTurnHandsOnItsUpdatesBeforeItThrows() async throws {
        let agent = try await Self.launchFixture(mode: "fail-after-updates")
        let seen = Counter()
        do {
            let response = try await agent.connection.newSession(
                NewSessionRequest(cwd: NSTemporaryDirectory(), mcpServers: []))
            let session = ACPSession(id: response.sessionId, agent: agent)
            await #expect(throws: JSONRPCErrorBody.self) {
                try await session.run([.text("hi")]) { _ in
                    // Slower than the agent: the updates are still coming when it fails.
                    usleep(2_000)
                    seen.add()
                }
            }
        } catch {
            await agent.close()
            throw error
        }
        await agent.close()
        #expect(seen.value == 20)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}

extension ACPAgentConnection {
    func setBeforeHandlingUpdate(_ hook: (@Sendable () async -> Void)?) {
        beforeHandlingUpdate = hook
    }

    /// Run `hook` when a wait for the updates read to be handled has to wait.
    func setOnUpdateWait(_ hook: (@Sendable (SessionId) -> Void)?) {
        sessionUpdates.setOnWait(hook)
    }
}
