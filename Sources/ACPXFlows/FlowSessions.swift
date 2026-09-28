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

    /// acpx's `createSessionWithClient` as a flow's persistent session starts
    /// (`ensureSessionBinding`): the agent launched in the agent's `cwd`, a new session
    /// named `name`, and its record written — the agent kept for the session's first turn,
    /// until that turn or ``releasePersistent(_:)`` lets it go. The creating attempt's stop
    /// calls it off (`control`). Returns the record.
    func createPersistent(agent: FlowAgent, name: String, control: FlowTurnControl) async throws -> SessionRecord

    /// acpx's `sendSessionDirect` as a flow's persistent turn runs it (`runPersistentPrompt`):
    /// the prompt in the session whose record `turn` names — with the agent it was created
    /// with, while that is kept, else a new one that takes the session back, and nothing
    /// else (`same-session-only`). The agent is let go when the turn ends, however it ends.
    func runPersistent(_ turn: FlowPersistentTurn) async throws

    /// Let go of the agent a session was created with, for a session whose first turn never
    /// came (acpx's `closePendingPersistentSessionClients`).
    func releasePersistent(_ recordId: String) async throws

    /// As the run ends: let go of each agent that an earlier attempt to let go of this run's
    /// sessions failed to reach — a first turn that failed, then failed to let go of its
    /// agent as well — so none is left kept, as acpx's run leaves none of its clients open
    /// (#219 review).
    func retryFailedReleases() async throws
}

extension FlowSessionRunner {
    /// Sessions whose agents are always let go need nothing retried.
    public func retryFailedReleases() async throws {}
}

/// A turn of a flow's persistent session, and what the runner hears of it: acpx's
/// `sendSessionDirect` options.
public struct FlowPersistentTurn: Sendable {
    /// The session's record id.
    public let recordId: String
    public let prompt: [ContentBlock]
    /// Each ACP message of the turn as it crosses the wire, in order, as JSON reads it —
    /// taking the session back included (acpx's `onAcpMessage`).
    public let onMessage: @Sendable (_ outbound: Bool, _ message: WireJSON) -> Void
    /// The attempt the turn runs for: acpx's `signal`.
    public let control: FlowTurnControl
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

    /// acpx's `createSessionBindingKey`: the agent, where it works, and the handle.
    static func persistentKey(agent: FlowAgent, handle: String) -> String {
        WireJSON.array([
            .text(agent.agentCommand), agent.agentArgv.map { .array($0.map(WireJSON.text)) } ?? .null,
            .text(agent.cwd), .text(handle)
        ]).stringified
    }

    /// The binding `ensureSessionBinding` makes of a persistent session it created, named
    /// `name`, with the record `record`.
    static func persistent(
        key: String, handle: String, name: String, profile: String?, agent: FlowAgent, record: SessionRecord
    ) -> FlowSessionBinding {
        FlowSessionBinding(
            key: key, handle: handle, bundleId: FlowRuntimeSupport.createSessionBundleId(handle: handle, key: key),
            name: name, profile: profile, agentName: agent.agentName, agentCommand: agent.agentCommand,
            agentArgv: agent.agentArgv, cwd: agent.cwd, acpxRecordId: record.acpxRecordId,
            acpSessionId: record.acpSessionId, agentSessionId: record.agentSessionId)
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
