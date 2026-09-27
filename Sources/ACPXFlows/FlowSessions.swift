import ACPXCore
import Foundation
import SwiftACP

/// acpx's `ResolvedFlowAgent`: the agent an ACP node's `profile` names — or the default
/// agent — as the CLI resolves it (`resolveAgentInvocation`), and where it works.
public struct FlowAgent: Sendable, Equatable {
    public var agentName: String
    public var agentCommand: String
    /// The exact argv to launch, when there is one.
    public var agentArgv: [String]?
    public var cwd: String

    public init(agentName: String, agentCommand: String, agentArgv: [String]?, cwd: String) {
        self.agentName = agentName
        self.agentCommand = agentCommand
        self.agentArgv = agentArgv
        self.cwd = cwd
    }

    /// The agent as a step's `agent` shows it: acpx's `{ ...resolvedAgent, agentArgv, cwd }`.
    var wire: WireJSON {
        .object([
            ("agentName", .text(agentName)), ("agentCommand", .text(agentCommand)),
            ("agentArgv", agentArgv.map { .array($0.map(WireJSON.text)) }), ("cwd", .text(cwd))
        ])
    }
}

/// The part of an ACP node's turn that is SwiftACP's CLI — launching the agent, opening its
/// session, sending the prompt — which the runner is handed (``FlowRunner/Options``), so
/// `ACPXFlows` needs none of the CLI.
public protocol FlowSessionRunner: Sendable {
    /// acpx's `runOnce` as an isolated node runs it (`runIsolatedPrompt`): the agent
    /// launched in the agent's `cwd`, a new session, and the prompt — with no deadline of
    /// its own; the attempt's ends it (``FlowTurn/control``). Returns the session's id.
    /// What the turn does is told to the turn's hooks as it happens, whether it succeeds
    /// or throws.
    func runIsolated(_ turn: FlowTurn) async throws -> String
}

/// One ACP turn of a flow node, and what the runner hears of it as it goes — acpx's
/// `runOnce` options.
public struct FlowTurn: Sendable {
    public let agent: FlowAgent
    public let prompt: [ContentBlock]
    /// Each ACP message as it crosses the wire, in order, as JSON reads it (acpx's
    /// `onAcpMessage`).
    public let onMessage: @Sendable (_ outbound: Bool, _ message: WireJSON) -> Void
    /// Each session update the client takes in (acpx's `onSessionUpdate`).
    public let onSessionUpdate: @Sendable (SessionNotification) -> Void
    /// Each client operation — a file read or write, a terminal, a permission notice —
    /// as the client reports it (acpx's `onClientOperation`).
    public let onClientOperation: @Sendable () -> Void
    /// The session is set up, and its prompt about to go (acpx's
    /// `output.setContext({ sessionId })`).
    public let onSessionReady: @Sendable (String) -> Void
    /// The attempt the turn runs for: acpx's `signal`.
    public let control: FlowTurnControl
}

/// The attempt an ACP turn runs for, as the turn sees it: acpx's `signal`, which aborts
/// at the step's deadline or an interrupt, and `assertControlAuthority`.
public final class FlowTurnControl: @unchecked Sendable {
    let attempt: FlowAttempt

    init(attempt: FlowAttempt) {
        self.attempt = attempt
    }

    /// Why the turn was stopped — the step's timeout, an interrupt — or `nil` while it may
    /// go on.
    public var stopReason: Error? { attempt.abortReason }

    /// acpx's `assertControlAuthority`: the stop reason, thrown once there is one.
    public func check() throws {
        if let reason = attempt.abortReason { throw reason }
    }

    /// `handler` runs once when the turn is stopped — at once when it already is. Returns
    /// what takes it off again.
    public func onStop(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        guard let remove = attempt.addAbortListener({ _ in handler() }) else {
            handler()
            return {}
        }
        let box = RemoveBox(remove)
        return { box.remove() }
    }

    /// acpx's `directExecutionError`: the agent gone once the turn was stopped — its
    /// client closed for that — fails the turn with why it was stopped.
    public func turnError(_ error: Error) -> Error {
        guard let reason = attempt.abortReason, ACPAgentConnection.isConnectionClosed(error) else { return error }
        return reason
    }

    private final class RemoveBox: @unchecked Sendable {
        let remove: () -> Void
        init(_ remove: @escaping () -> Void) { self.remove = remove }
    }
}

/// acpx's `FlowSessionBinding`: the session an ACP node's turn is bound to — for an
/// isolated node, one of its own (`createIsolatedSessionBinding`).
struct FlowSessionBinding: Sendable, Equatable {
    var key: String
    var handle: String
    var bundleId: String
    var name: String
    var profile: String?
    var agentName: String
    var agentCommand: String
    var agentArgv: [String]?
    var cwd: String
    var acpxRecordId: String
    var acpSessionId: String
    var agentSessionId: String?

    /// The binding as acpx writes it, its members in the order it builds it.
    var wire: WireJSON {
        .object([
            ("key", .text(key)), ("handle", .text(handle)), ("bundleId", .text(bundleId)), ("name", .text(name)),
            ("profile", profile.map(WireJSON.text)), ("agentName", .text(agentName)),
            ("agentCommand", .text(agentCommand)), ("agentArgv", agentArgv.map { .array($0.map(WireJSON.text)) }),
            ("cwd", .text(cwd)), ("acpxRecordId", .text(acpxRecordId)), ("acpSessionId", .text(acpSessionId)),
            ("agentSessionId", agentSessionId.map(WireJSON.text))
        ])
    }

    /// acpx's `createIsolatedSessionBinding`: keyed by the attempt, its record the key
    /// until the turn has a session.
    static func isolated(
        flowName: String, runId: String, attemptId: String, profile: String?, agent: FlowAgent
    ) -> FlowSessionBinding {
        let key = "isolated::\(attemptId)"
        let handle = "isolated"
        return FlowSessionBinding(
            key: key, handle: handle,
            bundleId: FlowRuntimeSupport.createSessionBundleId(
                handle: "\(handle)-\(attemptId)", key: "\(key)::\(agent.cwd)"),
            name: "\(flowName)-\(attemptId)-\(String(runId.suffix(8)))", profile: profile, agentName: agent.agentName,
            agentCommand: agent.agentCommand, agentArgv: agent.agentArgv, cwd: agent.cwd, acpxRecordId: key,
            acpSessionId: key)
    }
}
