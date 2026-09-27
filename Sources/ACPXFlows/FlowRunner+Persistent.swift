import ACPXCore
import Foundation
import SwiftACP

/// A run's persistent sessions: each binding by its key, as acpx's `state.sessionBindings`
/// holds them, and the sessions whose first turn has not come, their agents still kept
/// (acpx's `pendingPersistentSessionClients` and `pendingClientReleases`).
struct FlowPersistentSessions: Sendable {
    var bindings: [String: FlowSessionBinding] = [:]
    /// The record id of each session whose first turn has not come, by binding key, in the
    /// order they were made.
    var pending: [(key: String, recordId: String)] = []
    /// What takes each such session's release off the attempt that made it, by binding key.
    var releases: [String: @Sendable () -> Void] = [:]
}

// An ACP node's persistent session, as acpx's runner runs one (`ensureSessionBinding`,
// `executePersistentAcpPrompt`, `runPersistentPrompt`, `src/flows/runtime.ts`, v0.19.3): the
// session the node's handle has with its agent — made by the run's first node that needs
// it — and each turn in it through the CLI (``FlowSessionRunner``). Split from
// `FlowRunner+ACP.swift` to keep each file inside the 500-line limit.
extension FlowRunner {
    /// acpx's `ensureSessionBinding`: the session the node's handle has with its agent where
    /// it works — made the first time, and its agent kept for its first turn.
    func ensureSessionBinding(
        _ node: FlowNode, agent: FlowAgent, attempt: FlowAttempt, runDir: URL
    ) async throws -> FlowSessionBinding {
        let handle = node.sessionHandle ?? "main"
        let key = FlowSessionBinding.persistentKey(agent: agent, handle: handle)
        if let existing = persistentSessions.bindings[key] {
            try await attempt.own { try await self.ensureSessionBundle(existing, record: nil, runDir: runDir) }
            return existing
        }
        guard let sessions = options.sessions else { throw FlowRunError("No way to run ACP node \(node.id)") }
        let name = FlowRuntimeSupport.createSessionName(
            flowName: state.flowName, handle: handle, cwd: agent.cwd, runId: state.runId)
        let control = FlowTurnControl(attempt: attempt)
        let created = try await attempt.own {
            let record = try await sessions.createPersistent(agent: agent, name: name, control: control)
            let recordId = record.acpxRecordId
            let release = attempt.registerCancellation { _ in
                await self.forgetPending(key: key, recordId: recordId)
                try await sessions.releasePersistent(recordId)
            }
            await self.keepRelease(release, key: key)
            return record
        }
        try attempt.assertActive()
        let binding = FlowSessionBinding.persistent(
            key: key, handle: handle, name: name, profile: node.profile, agent: agent, record: created)
        setSessionBinding(binding)
        persistentSessions.pending.append((key, created.acpxRecordId))
        let record = try created.acpxRecord()
        try await attempt.own { try await self.ensureSessionBundle(binding, record: record, runDir: runDir) }
        return binding
    }

    /// acpx's `executePersistentAcpPrompt`.
    func executePersistentAcpPrompt(
        _ node: FlowNode, prepared: PreparedAcpPrompt, binding: FlowSessionBinding, attempt: FlowAttempt, runDir: URL
    ) async throws -> Executed {
        acpResults[attempt.attemptId]?.sessionInfo = binding
        try await attempt.own {
            try await self.appendAcpPromptPreparedTrace(
                binding, prepared.promptArtifact, attempt: attempt, runDir: runDir)
        }
        let prompt = try await attempt.own {
            try await self.runPersistentPrompt(binding, prepared: prepared, attempt: attempt, runDir: runDir)
        }
        return try await finishAcpPrompt(node, prompt: prompt, attempt: attempt, runDir: runDir)
    }

    /// acpx's `runPersistentPrompt`: the turn, with the agent the session was made with if
    /// it is still kept, and — however it went — the session as the turn left it published
    /// in the bundle, with where the turn's messages start in its conversation.
    private func runPersistentPrompt(
        _ binding: FlowSessionBinding, prepared: PreparedAcpPrompt, attempt: FlowAttempt, runDir: URL
    ) async throws -> TracedPromptResult {
        guard let sessions = options.sessions else { throw FlowRunError("No way to run ACP node \(attempt.nodeId)") }
        let capture = FlowQuietCapture(errorOutput: options.errorOutput)
        let before = try Self.resolveSessionRecord(binding.acpxRecordId)
        try attempt.assertActive()
        let events = FlowPromptEventCapture(log: store.sessionEventLog(runDir, binding))
        // The kept agent is the turn's now: nothing else lets it go.
        persistentSessions.pending.removeAll { $0.key == binding.key }
        persistentSessions.releases.removeValue(forKey: binding.key)?()
        let outcome: Result<Void, Error>
        do {
            let turn = FlowPersistentTurn(
                recordId: binding.acpxRecordId, prompt: try Self.contentBlocks(prepared.prompt),
                onMessage: { outbound, message in
                    capture.take(message)
                    events.take(outbound: outbound, message)
                },
                control: FlowTurnControl(attempt: attempt))
            try await sessions.runPersistent(turn)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        capture.flush()
        let receipt = events.receipt()
        let finalized = Result {
            try finalizePersistentPrompt(
                binding, before: before, capture: capture, receipt: receipt, prepared: prepared, attempt: attempt,
                runDir: runDir)
        }
        if case .failure(let error) = outcome { throw error }
        if let failure = receipt.failure { throw failure }
        guard receipt.events != nil else {
            throw FlowRunError("Missing ACP event capture for session \(binding.bundleId)")
        }
        return try finalized.get()
    }

    /// The finish of acpx's `runPersistentPrompt`: the session's record as the turn left
    /// it, and its binding with the session the record now names, published.
    private func finalizePersistentPrompt(
        _ binding: FlowSessionBinding, before: SessionRecord, capture: FlowQuietCapture,
        receipt: FlowPromptEventCapture.Receipt, prepared: PreparedAcpPrompt, attempt: FlowAttempt, runDir: URL
    ) throws -> TracedPromptResult {
        let rawText = capture.read()
        acpResults[attempt.attemptId]?.rawText = rawText
        let after = try Self.resolveSessionRecord(binding.acpxRecordId)
        var sessionInfo = binding
        sessionInfo.acpSessionId = after.acpSessionId
        sessionInfo.agentSessionId = after.agentSessionId
        setSessionBinding(sessionInfo)
        guard let record = try after.acpxRecord(), let earlier = try before.acpxRecord() else {
            throw FlowRunError("The session's record could not be written")
        }
        let messages = Self.messages(of: record)
        let messageStart = FlowRuntimeSupport.findConversationDeltaStart(Self.messages(of: earlier), messages)
        return try publishAcpCapture(
            sessionInfo, record: record, messageCount: messages.count, messageStart: messageStart, rawText: rawText,
            events: receipt.events, prepared: prepared, attempt: attempt, runDir: runDir)
    }

    /// `body`, then — whatever it came to — the run's sessions whose first turn never came let
    /// go, as acpx's `run` does in its `finally` (`closePendingPersistentSessionClients`). A
    /// failure to let one go is the run's.
    func withPendingSessionsReleased<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let outcome: Result<T, Error>
        do {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        try await closePendingPersistentSessions()
        return try outcome.get()
    }

    /// acpx's `closePendingPersistentSessionClients`: every session still kept for a first
    /// turn let go — each one tried, the first failure thrown.
    private func closePendingPersistentSessions() async throws {
        let pending = persistentSessions.pending
        persistentSessions.pending = []
        guard !pending.isEmpty, let sessions = options.sessions else { return }
        var failure: Error?
        for (key, recordId) in pending {
            persistentSessions.releases.removeValue(forKey: key)?()
            do {
                try await sessions.releasePersistent(recordId)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    /// The binding under its key, in the run's state too.
    private func setSessionBinding(_ binding: FlowSessionBinding) {
        persistentSessions.bindings[binding.key] = binding
        state.sessionBindings[binding.key] = binding.wire
    }

    private func keepRelease(_ release: @escaping @Sendable () -> Void, key: String) {
        persistentSessions.releases[key] = release
    }

    /// The creating attempt stopped: the session it made is let go now, not at the run's end.
    private func forgetPending(key: String, recordId: String) {
        persistentSessions.pending.removeAll { $0.key == key && $0.recordId == recordId }
        persistentSessions.releases.removeValue(forKey: key)
    }

    private func ensureSessionBundle(_ binding: FlowSessionBinding, record: WireJSON?, runDir: URL) throws {
        try store.ensureSessionBundle(runDir, state, binding, record: record)
    }

    /// The messages of a record as acpx holds it.
    private static func messages(of record: WireJSON) -> [WireJSON] {
        guard case .array(let messages)? = record["messages"] else { return [] }
        return messages
    }

    /// acpx's `resolveSessionRecord` for a record the run made: read by its id.
    static func resolveSessionRecord(_ recordId: String) throws -> SessionRecord {
        guard let record = SessionStore.loadRecord(recordId) else {
            throw FlowRunError("Session not found: \(recordId)")
        }
        return record
    }
}
