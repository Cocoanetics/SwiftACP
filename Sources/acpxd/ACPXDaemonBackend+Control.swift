import ACPXCore
import Foundation
import SwiftACP

// Running a control on a session — `set-mode`, `set model`, `set <option>` — as acpx
// runs one: directly on a session no owner holds, on the owner's agent otherwise, and
// within the caller's `--timeout`. Split from `ACPXDaemonBackend.swift` to keep that file
// inside the 500-line limit.
extension ACPXDaemonBackend {
    /// Run `body` holding the session's single turn slot, with a freshly-reloaded
    /// record, then stamp `last_used_at` and persist it. Serializes the control op
    /// against prompts and other control ops; reloading *after* acquiring means it
    /// builds on (and persists on top of) whatever turn it queued behind, rather than
    /// clobbering it. Also says whether connecting had to take the session back
    /// (acpx's `resumed`).
    ///
    /// `replacing` is what the control changes, which a reconnect first leaves alone.
    ///
    /// An agent can ask the client for something while it answers a control, as while
    /// it runs a turn. A control approves reads and asks about the rest, which no one
    /// can answer here, so `nonInteractivePermissions` decides — acpx's direct controls
    /// connect with `approve-reads` and the caller's non-interactive policy. Terminal
    /// output is capped by the caller's `terminalOutputCeiling`, as a turn's is.
    ///
    /// A session a queue owner holds (``SessionOwner``) has the control on the owner's
    /// agent, which stays — taken back as itself or not at all, should the owner have to take
    /// it back, as acpx's owner runs every control `same-session-only` (`runIdleControlWithRecord`,
    /// #290). One no owner holds has it as acpx runs a control then —
    /// directly (`withConnectedSession`): its agent connected for the control, and closed
    /// once it is done, however it went.
    ///
    /// `timeoutMs` bounds the control as acpx's `--timeout` does. Its wait for the session
    /// fails as `TIMEOUT` past it, in either case. A direct control has each step bounded
    /// by it — each step of connecting, and the request `body` makes, which is given the
    /// bound (`withOwnedDirectSession`, `withConnectedSession`). An owned control has one
    /// deadline from its arrival, over its wait, its connecting and its request
    /// (``ControlDeadline``): when it passes, what the control connects or runs on is put
    /// down, as acpx's owner closes its client (`runIdleControlWithRecord`), and the
    /// control fails as `TIMEOUT` — its owner still holding the session.
    ///
    /// An agent a direct control starts starts over the caller's `environment`, as acpx's
    /// direct control starts its client in the CLI's process; an owner's, over the one the
    /// owner was started with (#222). Under `verbose`, what that agent writes to stderr goes to
    /// the caller, with acpx's own lines — its client's log, whether the saved agent still runs,
    /// each preference put back — as acpx's direct control writes them in the CLI's process. An
    /// owner's control shows none: acpx's owner runs it, and its stderr is not the CLI's (#221).
    /// So with what the agent is offered, how it signs in, and the credentials and MCP servers it
    /// is given: a direct control's by its `client`, as acpx builds its client from the control's
    /// `--no-fs`, `--no-terminal`, `--auth-policy` and config; an owner's, as the prompt that
    /// started the owner asked (#246, #245).
    func withSessionTurn<T: Sendable>(
        _ sessionId: String, replacing: ReconnectReplay.Replacing, nonInteractivePermissions: String?,
        terminalOutputCeiling: Int?, timeoutMs: Int?, environment: [String: String]? = nil, verbose: Bool = false,
        client: ClientOptions = ClientOptions(), _ body: (Live, inout SessionRecord, _ timeout: Int?) async throws -> T
    ) async throws -> ControlOutcome<T> {
        let permissions = try TurnPermissions(mode: "approve-reads", nonInteractive: nonInteractivePermissions)
        let ceiling = try Self.terminalOutputCeiling(terminalOutputCeiling)
        let timeout = try Self.controlTimeout(timeoutMs)
        let initial = try resolveRecord(sessionId)
        let recordId = initial.acpxRecordId
        let arrived = DispatchTime.now()
        do {
            try await takeTurn(recordId, within: timeout)
        } catch {
            // A session an owner holds has the control wait on its owner, which answers the
            // wait's failure as its own.
            throw owners[recordId] == nil ? error : OwnedControlFailure(error)
        }
        // `defer` can't await; the hop to the queue actor is safe because release
        // hands the slot to the next FIFO waiter regardless of when it lands.
        defer { Task { await turnQueue.release(recordId) } }
        guard let current = findRecord(recordId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let direct = owners[recordId] == nil
        let deadline = direct ? nil : timeout.map { milliseconds in
            ControlDeadline(after: milliseconds - Self.milliseconds(since: arrived)) { [self] in
                await deadlinePasses(recordId)
            }
        }
        defer { deadline?.settle() }
        let step = direct ? timeout : nil
        let stderr = direct && verbose ? AgentStderrRelay() : nil
        let connecting = direct ? client : owners[recordId]?.client ?? ClientOptions()
        do {
            return try await relayingStderr(stderr, logger: recordId) {
                try await control(
                    current, direct: direct, replacing: replacing, deadline: deadline, step: step,
                    settings: CallerSettings(
                        handlers: permissions.handlers, terminalOutputCeiling: ceiling, timeoutMilliseconds: step,
                        sameSessionOnly: !direct, capabilities: .acpx(connecting), authPolicy: connecting.authPolicy,
                        callerConfig: connecting.config, stderr: stderr,
                        environment: direct ? environment : owners[recordId]?.environment),
                    body)
            }
        } catch {
            var failure = AgentFailure.shown(error)
            if let timeout, deadline?.hasPassed == true { failure = TimeoutError(milliseconds: timeout) }
            // An owner's control fails as acpx's owner answers one it could not carry out.
            throw direct ? failure : OwnedControlFailure(failure)
        }
    }

    /// The control once it has the session: connected, `body` run, the record saved. One run
    /// without an owner says why the session could not be taken back when a new session replaced
    /// it, as acpx's direct control returns `loadError`; an owner's says nothing of it.
    private func control<T: Sendable>(
        _ current: SessionRecord, direct: Bool, replacing: ReconnectReplay.Replacing, deadline: ControlDeadline?,
        step: Int?, settings: CallerSettings, _ body: (Live, inout SessionRecord, _ timeout: Int?) async throws -> T
    ) async throws -> ControlOutcome<T> {
        let recordId = current.acpxRecordId
        // What connecting changes — a reconnect may move the record to a new session — goes
        // into the record the control goes on with, as acpx's control goes on with the
        // record it connected: the block a reconnect built anew keeps the places it holds
        // for members still unset, which reading it back would lose.
        let changes = RecordChanges()
        let connected: Connected
        do {
            connected = try await connect(
                recordId: recordId, agentCommand: current.agentCommand, cwd: current.cwd, control: true,
                settings: settings, replacing: replacing, onRecordChange: { changes.add($0) })
        } catch {
            await settle(deadline, of: recordId)
            // Connecting can fail after it moved the record — the daemon began stopping
            // before the agent was held — and what it connected is saved all the same, as
            // acpx saves the record its control connected on the way out. A session its owner
            // holds is saved as used now, however connecting went, as the owner's
            // `checkpoint` saves a control that did not complete.
            if !changes.isEmpty || !direct {
                var moved = current
                changes.apply(to: &moved)
                if !direct { moved.lastUsedAt = nowISO() }
                do {
                    try SessionStore.writeRecord(moved)
                } catch let writeError {
                    log.warning("session record write failed after connecting for a control op: \(writeError)")
                }
            }
            throw error
        }
        let entry = connected.entry
        var reconnected = current
        changes.apply(to: &reconnected)
        var record = reconnected
        let result: T
        var answeredLate = false
        do {
            result = try await body(entry, &record, step)
            // An answer that came as the deadline passed is too late, as acpx's deadline
            // settles first (`deadline.wait`): the control is timed out, and its agent put down.
            if deadline?.settle() == false {
                answeredLate = true
                throw TimeoutError(milliseconds: 0)
            }
        } catch {
            await settle(deadline, of: recordId)
            // The agent may have gone meanwhile. How it is doing is saved whatever the
            // control came to, as acpx's controls save it on their way out. What the control
            // changed is saved only from a late answer, which acpx applies whenever it comes
            // (`acceptControl`). A session its owner holds is saved as used now, as the owner's
            // `checkpoint` saves it.
            // An agent whose connection is gone is ended first, as a turn's is: it can be
            // running still, and its pid would be kept.
            if direct || ACPAgentConnection.endedTheConnection(error) { try? await letGo(entry, of: recordId) }
            var saved = answeredLate ? record : reconnected
            if !direct { saved.lastUsedAt = nowISO() }
            saved.applyLifecycle(entry.agent.lifecycle)
            do {
                try SessionStore.writeRecord(saved)
            } catch let writeError {
                log.warning("session record write failed after a failed control op: \(writeError)")
            }
            throw error
        }
        if direct {
            try await letGo(entry, of: recordId)
            // What the agent connected for it answered `initialize` with, as acpx's direct control
            // records it (`withConnectedSession`, #119). An owner's control leaves it be.
            await record.applyInitialize(of: entry.agent)
        }
        record.applyLifecycle(entry.agent.lifecycle)
        record.lastUsedAt = nowISO()
        do {
            // The control op already took effect on the live agent, so don't fail
            // the call over a bookkeeping write — but don't hide it either.
            try SessionStore.writeRecord(record)
        } catch {
            log.warning("session record write failed after control op: \(error)")
        }
        return ControlOutcome(
            value: result, resumed: connected.resumed, owned: !direct, loadError: direct ? connected.loadError : nil)
    }

    /// An owned control's deadline passed: what the control connects or runs on is put down.
    private func deadlinePasses(_ recordId: String) async {
        await deadlinePassed?(recordId)
        await putDown(recordId)
    }

    /// The control is over. Should its deadline have passed, what the deadline puts down
    /// is down before the control goes on, as acpx's control waits for its client's close
    /// (`await retirement`) before it saves the record and ends: the agent's pid is gone
    /// from what is saved, and nothing is put down once the session is another's turn.
    private func settle(_ deadline: ControlDeadline?, of recordId: String) async {
        guard let deadline, !deadline.settle() else { return }
        await controlOverdue?(recordId)
        await deadline.finished()
    }

    /// Take the session's slot within `timeout`, as acpx bounds a control's wait for the
    /// session's turn by its `--timeout`: `TIMEOUT` past it, holding nothing.
    private func takeTurn(_ recordId: String, within timeout: Int?) async throws {
        let queue = turnQueue
        try await withTimeout(milliseconds: timeout, {
            try await queue.acquire(recordId, wait: true)
        }, discardingLate: { await queue.release(recordId) })
    }

    /// Close `entry`'s agent, and hold it no longer — throwing what closing it threw.
    private func letGo(_ entry: Live, of recordId: String) async throws {
        if live[recordId]?.agent === entry.agent { live.removeValue(forKey: recordId) }
        try await entry.agent.close()
    }

    /// A control's `--timeout`: none when not positive, as acpx takes it; one longer than
    /// a timer takes is refused, as acpx's CLI refuses it.
    static func controlTimeout(_ requested: Int?) throws -> Int? {
        guard let requested, requested > 0 else { return nil }
        guard requested <= JavaScriptNumber.maxTimerDelayMs else { throw DaemonError.invalidTimeout(requested) }
        return requested
    }

    private static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}

/// An owned control's deadline, as acpx's queue owner keeps one (`QueueControlDeadline`):
/// when it passes before the control is over, what the control connects or runs on is
/// put down (`putDown`), which fails the control.
final class ControlDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    private var settled = false
    private var watch: Task<Void, Never>?

    init(after milliseconds: Int, putDown: @escaping @Sendable () async -> Void) {
        let wait = UInt64(max(1, milliseconds)) * 1_000_000
        watch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, self.pass() else { return }
            await putDown()
        }
    }

    /// Whether it passed before the control was over.
    var hasPassed: Bool { lock.withLock { passed } }

    /// The control is over — acpx's `responseSettled` — and the deadline no longer
    /// passes. Returns whether it was over in time: `false` once the deadline has passed,
    /// when what it puts down is left to be done (``finished()``).
    @discardableResult
    func settle() -> Bool {
        let (watch, inTime): (Task<Void, Never>?, Bool) = lock.withLock {
            settled = true
            return (self.watch, !passed)
        }
        if inTime { watch?.cancel() }
        return inTime
    }

    /// Wait until what the deadline passing puts down is down: at once when it did not pass.
    func finished() async {
        await lock.withLock { watch }?.value
    }

    private func pass() -> Bool {
        lock.withLock {
            guard !settled else { return false }
            passed = true
            return true
        }
    }
}

/// An agent's failure, as acpx's CLI shows a control's (`formatErrorMessage`): its error
/// response by its message, and a connection that closed in the words of acpx's ACP SDK. The
/// daemon's tool reports the failure by that text, and the agent's error as the failure's own
/// (acpx's `extractAcpError`).
struct AgentFailure: LocalizedError, AcpErrorCarrier, ErrorWithCause {
    let message: String
    let acp: AcpErrorPayload?
    let cause: Error?
    var errorDescription: String? { message }

    /// `error`, as the tool reports it: an agent's error or a closed connection by acpx's
    /// words for it, anything else as it is.
    static func shown(_ error: Error) -> Error {
        guard error is JSONRPCErrorBody || (error as? JSONRPCPeerError) == .closed else { return error }
        return AgentFailure(message: TurnFailure.message(of: error), acp: TurnFailure.payload(of: error), cause: error)
    }
}
