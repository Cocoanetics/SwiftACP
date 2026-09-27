@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP

/// An ACP turn as a test scripts it (``FlowSessionRunner``): the messages it sends and
/// takes in, the session updates among them, when its session is ready, a wait for the
/// attempt to stop it — then its session's id, a failure, or the reason it was stopped.
final class ScriptedTurn: FlowSessionRunner, @unchecked Sendable {
    enum Step: Sendable {
        case outbound(String)
        case inbound(String)
        /// A `session/update`: on the wire, and to the client.
        case update(String)
        case ready(String)
        case clientOperation
        /// Interrupt the run, as a Ctrl-C would, without waiting for it to answer.
        case interrupt
        /// Time the attempt out, as its timer would at `timeoutMs`.
        case timeOut(Double)
        /// Take this long over the next step.
        case pause(milliseconds: Int)
        case waitForStop

        var isUpdate: Bool {
            if case .update = self { return true }
            return false
        }
    }

    enum Ending: Sendable {
        case session(String)
        case failure(any Error)
        case stopReason
    }

    private let steps: [Step]
    private let ending: Ending
    private let lock = NSLock()
    private var seenPrompts: [[ContentBlock]] = []
    private var seenCwds: [String] = []
    private var runner: FlowRunner?
    private var control: FlowTurnControl?

    /// Time the turn's attempt out now, as its timer would at `timeoutMs`.
    func timeOut(_ timeoutMs: Double) {
        lock.withLock { self.control }?.attempt.cancel(FlowTimeoutError(timeoutMs: timeoutMs))
    }

    /// Take the runner that ``Step/interrupt`` interrupts.
    func interrupts(_ runner: FlowRunner) {
        lock.withLock { self.runner = runner }
    }

    init(_ steps: [Step], ending: Ending = .session("s-1")) {
        self.steps = steps
        self.ending = ending
    }

    var prompts: [[ContentBlock]] { lock.withLock { seenPrompts } }
    var cwds: [String] { lock.withLock { seenCwds } }

    /// A whole turn in session `s-1`, answered with `text`.
    static func answering(_ text: String) -> [Step] {
        let chunk = WireJSON.object([
            ("sessionUpdate", .text("agent_message_chunk")),
            ("content", .object([("type", .text("text")), ("text", .text(text))]))
        ]).stringified
        return [
            .outbound(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#),
            .inbound(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}"#),
            .outbound(#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/","mcpServers":[]}}"#),
            .inbound(#"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s-1"}}"#),
            .ready("s-1"),
            .outbound(#"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s-1"}}"#),
            .update(#"{"sessionId":"s-1","update":\#(chunk)}"#),
            .inbound(#"{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}"#)
        ]
    }

    func createPersistent(agent: FlowAgent, name: String, control: FlowTurnControl) async throws -> SessionRecord {
        throw FlowRunError("A scripted turn has no persistent sessions")
    }

    func runPersistent(_ turn: FlowPersistentTurn) async throws {
        throw FlowRunError("A scripted turn has no persistent sessions")
    }

    func releasePersistent(_ recordId: String) async throws {}

    func runIsolated(_ turn: FlowTurn) async throws -> String {
        lock.withLock {
            seenPrompts.append(turn.prompt)
            seenCwds.append(turn.agent.cwd)
            control = turn.control
        }
        for step in steps {
            switch step {
            case .outbound(let text): turn.onMessage(true, try WireJSON.parse(text))
            case .inbound(let text): turn.onMessage(false, try WireJSON.parse(text))
            case .update(let params):
                turn.onMessage(false, try WireJSON.parse(
                    #"{"jsonrpc":"2.0","method":"session/update","params":\#(params)}"#))
                turn.onSessionUpdate(try JSONDecoder().decode(SessionNotification.self, from: Data(params.utf8)))
            case .ready(let sessionId): turn.onSessionReady(sessionId)
            case .clientOperation: turn.onClientOperation()
            case .interrupt:
                let runner = lock.withLock { self.runner }
                Task { await runner?.interrupt() }
            case .timeOut(let timeoutMs): turn.control.attempt.cancel(FlowTimeoutError(timeoutMs: timeoutMs))
            case .pause(let milliseconds): try? await Task.sleep(for: .milliseconds(milliseconds))
            case .waitForStop:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let once = OnceResume(continuation)
                    _ = turn.control.onStop { once.resume() }
                }
            }
        }
        switch ending {
        case .session(let sessionId): return sessionId
        case .failure(let error): throw error
        case .stopReason: throw turn.control.stopReason ?? CancellationError()
        }
    }
}

/// A continuation resumed once, however often it is told to.
final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }?.resume()
    }
}

/// Lines written, in order.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var all: [String] { lock.withLock { lines } }

    func add(_ line: String) {
        lock.withLock { lines.append(line) }
    }
}

extension WireJSON {
    var arrayItems: [WireJSON] {
        if case .array(let items) = self { return items }
        return []
    }

    var arrayCount: Int { arrayItems.count }
}
