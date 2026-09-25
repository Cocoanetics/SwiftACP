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
    /// agent, which stays. One no owner holds has it as acpx runs a control then —
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
    func withSessionTurn<T: Sendable>(
        _ sessionId: String, replacing: ReconnectReplay.Replacing, nonInteractivePermissions: String?,
        terminalOutputCeiling: Int?, timeoutMs: Int?,
        _ body: (Live, inout SessionRecord, _ timeout: Int?) async throws -> T
    ) async throws -> (value: T, resumed: Bool) {
        let permissions = try TurnPermissions(mode: "approve-reads", nonInteractive: nonInteractivePermissions)
        let ceiling = try Self.terminalOutputCeiling(terminalOutputCeiling)
        let timeout = try Self.controlTimeout(timeoutMs)
        guard let initial = findRecord(sessionId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let recordId = initial.acpxRecordId
        let arrived = DispatchTime.now()
        try await takeTurn(recordId, within: timeout)
        // `defer` can't await; the hop to the queue actor is safe because release
        // hands the slot to the next FIFO waiter regardless of when it lands.
        defer { Task { await turnQueue.release(recordId) } }
        guard let current = findRecord(recordId) else {
            throw DaemonError.sessionNotFound(sessionId)
        }
        let direct = owners[recordId] == nil
        let deadline = direct ? nil : timeout.map { milliseconds in
            ControlDeadline(after: milliseconds - Self.milliseconds(since: arrived)) { [self] in
                await putDown(recordId)
            }
        }
        defer { deadline?.settle() }
        let step = direct ? timeout : nil
        do {
            return try await control(
                current, direct: direct, replacing: replacing, deadline: deadline, step: step,
                settings: CallerSettings(
                    handlers: permissions.handlers, terminalOutputCeiling: ceiling, timeoutMilliseconds: step),
                body)
        } catch {
            if let timeout, deadline?.hasPassed == true { throw TimeoutError(milliseconds: timeout) }
            throw error
        }
    }

    /// The control once it has the session: connected, `body` run, the record saved.
    private func control<T: Sendable>(
        _ current: SessionRecord, direct: Bool, replacing: ReconnectReplay.Replacing, deadline: ControlDeadline?,
        step: Int?, settings: CallerSettings, _ body: (Live, inout SessionRecord, _ timeout: Int?) async throws -> T
    ) async throws -> (value: T, resumed: Bool) {
        let recordId = current.acpxRecordId
        // What connecting changes — a reconnect may move the record to a new session — goes
        // into the record the control goes on with, as acpx's control goes on with the
        // record it connected: the block a reconnect built anew keeps the places it holds
        // for members still unset, which reading it back would lose.
        let changes = RecordChanges()
        let entry: Live, resumed: Bool
        do {
            (entry, resumed) = try await connect(
                recordId: recordId, agentCommand: current.agentCommand, cwd: current.cwd,
                mcpServers: current.acpx?.mcpServers, control: true, settings: settings,
                replacing: replacing, onRecordChange: { changes.add($0) })
        } catch {
            // Connecting can fail after it moved the record — the daemon began stopping
            // before the agent was held — and what it connected is saved all the same, as
            // acpx saves the record its control connected on the way out.
            if !changes.isEmpty {
                var moved = current
                changes.apply(to: &moved)
                do {
                    try SessionStore.writeRecord(moved)
                } catch let writeError {
                    log.warning("session record write failed after connecting for a control op: \(writeError)")
                }
            }
            throw error
        }
        var connected = current
        changes.apply(to: &connected)
        var record = connected
        let result: T
        do {
            result = try await body(entry, &record, step)
            deadline?.settle()
        } catch {
            deadline?.settle()
            // The agent may have gone meanwhile. How it is doing is saved whatever the
            // control came to, as acpx's controls save it on their way out — but nothing
            // of the control that failed.
            // An agent whose connection is gone is ended first, as a turn's is: it can be
            // running still, and its pid would be kept.
            if direct || ACPAgentConnection.endedTheConnection(error) { await letGo(entry, of: recordId) }
            connected.applyLifecycle(entry.agent.lifecycle)
            do {
                try SessionStore.writeRecord(connected)
            } catch let writeError {
                log.warning("session record write failed after a failed control op: \(writeError)")
            }
            throw error
        }
        if direct { await letGo(entry, of: recordId) }
        record.applyLifecycle(entry.agent.lifecycle)
        record.lastUsedAt = nowISO()
        do {
            // The control op already took effect on the live agent, so don't fail
            // the call over a bookkeeping write — but don't hide it either.
            try SessionStore.writeRecord(record)
        } catch {
            log.warning("session record write failed after control op: \(error)")
        }
        return (result, resumed)
    }

    /// Take the session's slot within `timeout`, as acpx bounds a control's wait for the
    /// session's turn by its `--timeout`: `TIMEOUT` past it, holding nothing.
    private func takeTurn(_ recordId: String, within timeout: Int?) async throws {
        let queue = turnQueue
        try await withTimeout(milliseconds: timeout, {
            try await queue.acquire(recordId, wait: true)
        }, discardingLate: { await queue.release(recordId) })
    }

    /// Close `entry`'s agent, and hold it no longer.
    private func letGo(_ entry: Live, of recordId: String) async {
        if live[recordId]?.agent === entry.agent { live.removeValue(forKey: recordId) }
        await entry.agent.close()
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

    /// The control is over — acpx's `responseSettled` — and the deadline no longer passes.
    func settle() {
        let watch: Task<Void, Never>? = lock.withLock {
            settled = true
            return self.watch
        }
        watch?.cancel()
    }

    private func pass() -> Bool {
        lock.withLock {
            guard !settled else { return false }
            passed = true
            return true
        }
    }
}
