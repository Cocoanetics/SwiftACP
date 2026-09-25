import ACPXCore
import Foundation
import SwiftACP

// A control sent while a session runs a prompt, taken as acpx 0.19.1's queue owner takes
// it (`QueueOwnerControlAdmission`, `src/session/queue/control-admission.ts`): on the
// prompt's own agent, at once, rather than once the prompt is over. Split from
// `ACPXDaemonBackend+Control.swift` to keep that file inside the 500-line limit.
extension ACPXDaemonBackend {
    /// A control's request, and what its answer changes in the record. The request is
    /// given what it runs on and the record as it stands; the change is made to the
    /// record the control saves.
    struct ControlStep<Response: Sendable, Value: Sendable>: Sendable {
        let request: @Sendable (Live, SessionRecord, _ timeout: Int?) async throws -> Response
        let apply: @Sendable (Response, inout SessionRecord) -> Value
    }

    /// Run a control as acpx's queue owner runs one (`QueueOwnerControlAdmission.run`): on
    /// the prompt's agent while the session runs a prompt
    /// (``control(duringPromptOf:_:timeout:_:)``), and between turns otherwise
    /// (``withSessionTurn(_:replacing:nonInteractivePermissions:terminalOutputCeiling:timeoutMs:_:)``).
    func runControl<Response: Sendable, Value: Sendable>(
        _ sessionId: String, replacing: ReconnectReplay.Replacing, nonInteractivePermissions: String?,
        terminalOutputCeiling: Int?, timeoutMs: Int?, _ step: ControlStep<Response, Value>
    ) async throws -> (value: Value, resumed: Bool) {
        _ = try TurnPermissions(mode: "approve-reads", nonInteractive: nonInteractivePermissions)
        _ = try Self.terminalOutputCeiling(terminalOutputCeiling)
        let timeout = try Self.controlTimeout(timeoutMs)
        if let record = findRecord(sessionId), let ticket = tickets[record.acpxRecordId], !ticket.sealed {
            // Its failure is said as one between turns is (``AgentFailure/shown(_:)``).
            do {
                return (try await control(duringPromptOf: record.acpxRecordId, ticket, timeout: timeout, step), false)
            } catch {
                throw AgentFailure.shown(error)
            }
        }
        return try await withSessionTurn(
            sessionId, replacing: replacing, nonInteractivePermissions: nonInteractivePermissions,
            terminalOutputCeiling: terminalOutputCeiling, timeoutMs: timeoutMs) { entry, record, timeout in
            let response = try await step.request(entry, record, timeout)
            return step.apply(response, &record)
        }
    }

    /// A control during a prompt, as acpx's owner runs one on the prompt's ticket:
    /// - it waits for the controls before it, and for the prompt to go out;
    /// - it runs on the prompt's agent, whose handlers answer what the agent asks meanwhile;
    /// - its exchange is the turn's, shown to the prompt's client and kept in its journal;
    /// - what it changes goes into the prompt's record, saved at once (`acceptControl`).
    ///
    /// Its `timeout` runs from now. Past it, the caller hears `TIMEOUT` at once. A control
    /// whose request has not gone out by then sends none; one whose request has puts the
    /// prompt's agent down, as acpx's control closes the prompt's client (`retire`).
    private func control<Response: Sendable, Value: Sendable>(
        duringPromptOf recordId: String, _ ticket: PromptControlTicket, timeout: Int?,
        _ step: ControlStep<Response, Value>
    ) async throws -> Value {
        let expiry = timeout.map { ContinuousClock.now + .milliseconds($0) }
        let sent = WriteMark()
        let previous = ticket.tail
        let persister = ticket.persister
        let operation = Task { [self] () async throws -> Value in
            await previous?.value
            try await ticket.ready()
            // Past its deadline while it waited: nothing goes out (acpx's `assertActive`).
            if let timeout, let expiry, ContinuousClock.now >= expiry { throw TimeoutError(milliseconds: timeout) }
            guard let entry = live[recordId] else { throw JSONRPCPeerError.closed }
            let record = await persister.record
            sent.mark()
            let response = try await step.request(entry, record, nil)
            return await persister.control { step.apply(response, &$0) }
        }
        ticket.tail = Task { _ = await operation.result }
        await controlTakenDuringPrompt?(recordId)
        guard let timeout else { return try await operation.value }
        do {
            return try await withTimeout(milliseconds: timeout) { try await operation.value }
        } catch let timedOut as TimeoutError {
            if sent.happened { Task { await self.putDown(recordId) } }
            throw timedOut
        }
    }

    /// The prompt's turn is over, as acpx's `seal` says (`onPromptFinalizing`): a control
    /// from now on waits for the session's next turn, and those taken are done before the
    /// turn's last save.
    func sealControls(of recordId: String) async {
        await tickets[recordId]?.seal()?.value
    }
}

/// The controls a prompt's turn takes while it runs: acpx's `PromptControlTicket`. Opened
/// as the turn starts, ready once its prompt goes out, sealed when the turn is over. Held by
/// the backend and used only on its actor.
final class PromptControlTicket: @unchecked Sendable {
    /// The prompt's persister, whose record a control changes and saves.
    let persister: TurnPersister
    private(set) var published = false
    private(set) var sealed = false
    /// The controls waiting for the prompt to go out.
    private var waiting: [CheckedContinuation<Void, Error>] = []
    /// The last control taken, which the next runs after: acpx's `rawTail`.
    var tail: Task<Void, Never>?

    init(persister: TurnPersister) {
        self.persister = persister
    }

    /// The prompt went out, as acpx's owner publishes its controls (`onPromptActive`): the
    /// controls waiting for it run, in turn.
    func publish() {
        guard !published, !sealed else { return }
        published = true
        let ready = waiting
        waiting = []
        ready.forEach { $0.resume() }
    }

    /// The turn is over: no control is taken from now on. Those still waiting for a prompt
    /// that never went out fail, as acpx's `seal` fails them. Returns the last control
    /// taken, for the turn to wait for.
    @discardableResult
    func seal() -> Task<Void, Never>? {
        guard !sealed else { return tail }
        sealed = true
        if !published {
            let failing = waiting
            waiting = []
            failing.forEach { $0.resume(throwing: PromptEndedBeforeControls()) }
        }
        return tail
    }

    /// Wait for the prompt to go out.
    func ready() async throws {
        if published { return }
        if sealed { throw PromptEndedBeforeControls() }
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }
}

/// acpx's `QueueConnectionError` for a control that waited on a prompt which ended before it
/// went out.
struct PromptEndedBeforeControls: LocalizedError, OutputErrorMeta {
    var errorDescription: String? { "Prompt ended before controls became ready" }
    var outputCode: String? { "RUNTIME" }
    var detailCode: String? { "QUEUE_CONTROL_REQUEST_FAILED" }
    var origin: String? { "queue" }
    var retryable: Bool? { true }
}

/// Set once anything is written to the agent. Marked from the transport's writer
/// task, so lock-protected.
final class WriteMark: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.withLock { marked = true }
    }

    func unmark() {
        lock.withLock { marked = false }
    }

    var happened: Bool {
        lock.withLock { marked }
    }

}
