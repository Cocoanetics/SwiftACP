import ACPXCore
import Foundation
import SwiftACP

// An ACP node, as acpx's runner runs one (`executeAcpNode` and what it calls,
// `src/flows/runtime.ts`, v0.19.3): its prompt made in the host, a turn with the agent the
// node names — here the CLI's (``FlowSessionRunner``) — every ACP message of it kept in the
// bundle, and its answer parsed. Split from `FlowRunner.swift` to keep each file inside the
// 500-line limit.
extension FlowRunner {
    /// What an ACP node's attempt has come to so far — acpx's `context.acpResult`, which a
    /// step that fails keeps.
    struct AcpResult: Sendable {
        var promptText: [UInt16]
        var rawText: [UInt16]?
        var sessionInfo: FlowSessionBinding?
        var agentInfo: FlowAgent
        var trace: FlowStepTrace?

        /// The step as far as it came, with `trace` for its trace.
        func executed(output: FlowValue = .undefined, fromHost: Bool = false, trace: FlowStepTrace?) -> Executed {
            Executed(
                output: output, outputFromHost: fromHost, promptText: .string(promptText),
                rawText: rawText.map(WireJSON.string), sessionInfo: sessionInfo?.wire, agentInfo: agentInfo.wire,
                trace: trace)
        }
    }

    /// acpx's `PreparedAcpPrompt`.
    struct PreparedAcpPrompt: Sendable {
        let agent: FlowAgent
        /// The prompt as the host gave it: `{value}`, or how JSON failed to write it.
        let prompt: WireJSON
        let promptArtifact: FlowArtifactRef
    }

    /// acpx's `TracedPromptResult`.
    struct TracedPromptResult: Sendable {
        let rawText: [UInt16]
        let sessionInfo: FlowSessionBinding
        let conversation: WireJSON?
        let rawResponseArtifact: FlowArtifactRef
    }

    /// acpx's `executeAcpNode`.
    func executeAcpNode(_ node: FlowNode, attempt: FlowAttempt, runDir: URL) async throws -> Executed {
        let prepared = try await prepareAcpPrompt(node, attempt: attempt, runDir: runDir)
        guard node.isolated else {
            throw FlowRunError("ACP nodes with a persistent session are not supported by SwiftACP's acpx yet")
        }
        return try await executeIsolatedAcpPrompt(node, prepared: prepared, attempt: attempt, runDir: runDir)
    }

    /// acpx's `prepareAcpPrompt`: the agent, where it works, and the prompt — its text the
    /// step's detail and an artifact.
    private func prepareAcpPrompt(_ node: FlowNode, attempt: FlowAttempt, runDir: URL) async throws
        -> PreparedAcpPrompt {
        guard let resolveAgent = options.resolveAgent else {
            throw FlowRunError("No agent to run ACP node \(node.id) with")
        }
        var agent = try resolveAgent(node.profile)
        agent.cwd = try await resolveNodeCwd(node, defaultCwd: agent.cwd, attempt: attempt)
        try attempt.assertActive()
        let reply = try await invokeReply(node, "prompt", attempt: attempt)
        try attempt.assertActive()
        if let failure = reply?["promptTextError"] {
            throw FlowHost.CallbackError(
                message: failure["message"]?.stringValue ?? "", isError: failure["isError"] == .bool(true))
        }
        guard case .string(let promptText)? = reply?["promptText"] else {
            throw FlowRunError("The flow host made no prompt for ACP node \(node.id)")
        }
        acpResults[attempt.attemptId] = AcpResult(promptText: promptText, agentInfo: agent)
        let detail = FlowRuntimeSupport.summarizePrompt(promptText, explicitDetail: node.statusDetail)
        state.set("statusDetail", detail)
        try await attempt.own { try await self.writeAcpPromptHeartbeat(attempt, runDir: runDir) }
        let promptArtifact = try await attempt.own {
            try await self.writeAcpArtifact(.text(promptText), attempt: attempt, sessionId: nil, runDir: runDir)
        }
        var trace = FlowStepTrace()
        trace["promptArtifact"] = promptArtifact.wire
        acpResults[attempt.attemptId]?.trace = trace
        return PreparedAcpPrompt(
            agent: agent, prompt: reply?.removing("promptText") ?? .null, promptArtifact: promptArtifact)
    }

    /// acpx's `resolveNodeCwd`: the node's `cwd` — a function's, the host resolves — against
    /// the agent's.
    private func resolveNodeCwd(_ node: FlowNode, defaultCwd: String, attempt: FlowAttempt) async throws -> String {
        guard node.callbacks.contains("cwd") else { return ACPXPaths.resolve(node.cwd ?? defaultCwd, base: defaultCwd) }
        let reply = try await invokeReply(node, "cwd", attempt: attempt, extra: [("defaultCwd", .text(defaultCwd))])
        return reply?["value"]?.stringValue ?? defaultCwd
    }

    private func writeAcpPromptHeartbeat(_ attempt: FlowAttempt, runDir: URL) throws {
        try store.writeLive(
            runDir, &state, scope: "node", type: "node_heartbeat", nodeId: attempt.nodeId, attemptId: attempt.attemptId,
            payload: .object([("statusDetail", state.member("statusDetail"))]))
    }

    private func writeAcpArtifact(
        _ content: FlowRunStore.ArtifactContent, attempt: FlowAttempt, sessionId: String?, runDir: URL
    ) throws -> FlowArtifactRef {
        try store.writeArtifact(
            runDir, state, content: content, mediaType: "text/plain", extension: "txt", nodeId: attempt.nodeId,
            attemptId: attempt.attemptId, sessionId: sessionId)
    }

    /// acpx's `executeIsolatedAcpPrompt`: a session of the attempt's own, opened in the
    /// bundle before the turn.
    private func executeIsolatedAcpPrompt(
        _ node: FlowNode, prepared: PreparedAcpPrompt, attempt: FlowAttempt, runDir: URL
    ) async throws -> Executed {
        let binding = FlowSessionBinding.isolated(
            flowName: state.flowName, runId: state.runId, attemptId: attempt.attemptId, profile: node.profile,
            agent: prepared.agent)
        acpResults[attempt.attemptId]?.sessionInfo = binding
        try await attempt.own {
            try await self.initializeIsolatedSessionBundle(binding, attempt: attempt, runDir: runDir)
        }
        try await attempt.own {
            try await self.appendAcpPromptPreparedTrace(
                binding, prepared.promptArtifact, attempt: attempt, runDir: runDir)
        }
        let prompt = try await attempt.own {
            try await self.runIsolatedPrompt(binding, prepared: prepared, attempt: attempt, runDir: runDir)
        }
        return try await finishAcpPrompt(node, prompt: prompt, attempt: attempt, runDir: runDir)
    }

    /// acpx's `initializeIsolatedSessionBundle`: the session's record, empty, as of the
    /// attempt's start.
    private func initializeIsolatedSessionBundle(_ binding: FlowSessionBinding, attempt: FlowAttempt, runDir: URL)
        throws {
        let conversation = try Self.conversation(SessionRecord(
            acpxRecordId: binding.acpxRecordId, acpSessionId: binding.acpSessionId, agentCommand: binding.agentCommand,
            cwd: binding.cwd, createdAt: attempt.startedAt, lastUsedAt: attempt.startedAt))
        let record = FlowRuntimeSupport.createSyntheticSessionRecord(
            binding: binding, createdAt: attempt.startedAt, updatedAt: attempt.startedAt, conversation: conversation,
            withAcpx: false, lastSeq: 0)
        try store.ensureSessionBundle(runDir, state, binding, record: record)
    }

    private func appendAcpPromptPreparedTrace(
        _ binding: FlowSessionBinding, _ promptArtifact: FlowArtifactRef, attempt: FlowAttempt, runDir: URL
    ) throws {
        try store.appendTrace(
            runDir, state, scope: "acp", type: "acp_prompt_prepared", nodeId: attempt.nodeId,
            attemptId: attempt.attemptId, sessionId: binding.bundleId,
            payload: .object([("sessionId", .text(binding.bundleId)), ("promptArtifact", promptArtifact.wire)]))
    }

    /// acpx's `finishAcpPrompt`: the answer traced, then parsed.
    private func finishAcpPrompt(
        _ node: FlowNode, prompt: TracedPromptResult, attempt: FlowAttempt, runDir: URL
    ) async throws -> Executed {
        try await attempt.own { try await self.appendAcpResponseParsedTrace(prompt, attempt: attempt, runDir: runDir) }
        try attempt.assertActive()
        let output: FlowValue
        let fromHost = node.callbacks.contains("parse")
        if fromHost {
            output = try await invoke(node, "parse", attempt: attempt, argument: .string(prompt.rawText))
        } else {
            output = .json(.string(prompt.rawText))
        }
        try attempt.assertActive()
        guard let result = acpResults[attempt.attemptId] else { throw FlowRunError("undefined") }
        return result.executed(output: output, fromHost: fromHost, trace: result.trace)
    }

    private func appendAcpResponseParsedTrace(_ prompt: TracedPromptResult, attempt: FlowAttempt, runDir: URL) throws {
        try store.appendTrace(
            runDir, state, scope: "acp", type: "acp_response_parsed", nodeId: attempt.nodeId,
            attemptId: attempt.attemptId, sessionId: prompt.sessionInfo.bundleId,
            payload: .object([
                ("sessionId", .text(prompt.sessionInfo.bundleId)), ("conversation", prompt.conversation),
                ("rawResponseArtifact", prompt.rawResponseArtifact.wire)
            ]))
    }

    /// acpx's `runIsolatedPrompt`: the turn, run once, its conversation recorded as it
    /// goes, and — however it went — published in the bundle.
    private func runIsolatedPrompt(
        _ binding: FlowSessionBinding, prepared: PreparedAcpPrompt, attempt: FlowAttempt, runDir: URL
    ) async throws -> TracedPromptResult {
        guard let sessions = options.sessions else { throw FlowRunError("No way to run ACP node \(attempt.nodeId)") }
        let blocks = try Self.contentBlocks(prepared.prompt)
        let capture = FlowQuietCapture(errorOutput: options.errorOutput)
        var initial = SessionRecord(
            acpxRecordId: binding.acpxRecordId, acpSessionId: binding.acpSessionId, agentCommand: binding.agentCommand,
            cwd: binding.cwd, createdAt: attempt.startedAt, lastUsedAt: attempt.startedAt)
        ConversationModel.recordPromptSubmission(into: &initial, prompt: blocks, timestamp: attempt.startedAt)
        let conversation = FlowTurnConversation(initial)
        let events = FlowPromptEventCapture(log: store.sessionEventLog(runDir, binding))
        let turn = FlowTurn(
            agent: prepared.agent, prompt: blocks,
            onMessage: { outbound, message in
                capture.take(message)
                events.take(outbound: outbound, message)
            },
            onSessionUpdate: { conversation.record($0) }, onClientOperation: { conversation.recordClientOperation() },
            onSessionReady: { capture.sessionReady($0) }, control: FlowTurnControl(attempt: attempt))
        let outcome: Result<String, Error>
        do {
            outcome = .success(try await sessions.runIsolated(turn))
        } catch {
            outcome = .failure(error)
        }
        capture.flush()
        let receipt = events.receipt()
        let finalized = Result {
            try finalizeIsolatedPrompt(
                binding, outcome: outcome, capture: capture, conversation: conversation, receipt: receipt,
                prepared: prepared, attempt: attempt, runDir: runDir)
        }
        if case .failure(let error) = outcome { throw error }
        if let failure = receipt.failure { throw failure }
        guard receipt.events != nil else {
            throw FlowRunError("Missing ACP event capture for session \(binding.bundleId)")
        }
        return try finalized.get()
    }

    /// The finish of acpx's `runIsolatedPrompt`: the session as the turn left it, its
    /// record made of the conversation, published.
    private func finalizeIsolatedPrompt(
        _ binding: FlowSessionBinding, outcome: Result<String, Error>, capture: FlowQuietCapture,
        conversation: FlowTurnConversation, receipt: FlowPromptEventCapture.Receipt, prepared: PreparedAcpPrompt,
        attempt: FlowAttempt, runDir: URL
    ) throws -> TracedPromptResult {
        let rawText = capture.read()
        acpResults[attempt.attemptId]?.rawText = rawText
        let sessionId = (try? outcome.get()) ?? capture.sessionId
        var sessionInfo = binding
        if let sessionId {
            sessionInfo.acpxRecordId = sessionId
            sessionInfo.acpSessionId = sessionId
        }
        let (held, touched) = conversation.snapshot()
        let record = FlowRuntimeSupport.createSyntheticSessionRecord(
            binding: sessionInfo, createdAt: attempt.startedAt, updatedAt: held.updatedAt,
            conversation: try Self.conversation(held), withAcpx: touched, lastSeq: receipt.lastSeq)
        return try publishAcpCapture(
            sessionInfo, record: record, messageCount: held.messages.count, messageStart: 0, rawText: rawText,
            events: receipt.events, prepared: prepared, attempt: attempt, runDir: runDir)
    }

    /// acpx's `publishAcpCapture`: the session's binding and record written, where its
    /// events are in the log, and the answer kept as an artifact — the step's trace growing
    /// as each is done.
    private func publishAcpCapture(
        _ sessionInfo: FlowSessionBinding, record: WireJSON, messageCount: Int, messageStart: Int, rawText: [UInt16],
        events: (start: Int, end: Int)?, prepared: PreparedAcpPrompt, attempt: FlowAttempt, runDir: URL
    ) throws -> TracedPromptResult {
        acpResults[attempt.attemptId]?.sessionInfo = sessionInfo
        var trace = FlowStepTrace()
        trace["sessionId"] = .text(sessionInfo.bundleId)
        trace["promptArtifact"] = prepared.promptArtifact.wire
        acpResults[attempt.attemptId]?.trace = trace
        try store.ensureSessionBundle(runDir, state, sessionInfo)
        try store.writeSessionRecord(runDir, sessionInfo, record)
        if let events {
            trace["conversation"] = .object([
                ("sessionId", .text(sessionInfo.bundleId)), ("messageStart", .number(Double(messageStart))),
                ("messageEnd", .number(Double(max(messageStart, messageCount - 1)))),
                ("eventStartSeq", .number(Double(events.start))), ("eventEndSeq", .number(Double(events.end)))
            ])
            acpResults[attempt.attemptId]?.trace = trace
        }
        let rawResponseArtifact = try writeAcpArtifact(
            .text(rawText), attempt: attempt, sessionId: sessionInfo.bundleId, runDir: runDir)
        trace["rawResponseArtifact"] = rawResponseArtifact.wire
        acpResults[attempt.attemptId]?.trace = trace
        return TracedPromptResult(
            rawText: rawText, sessionInfo: sessionInfo, conversation: trace["conversation"],
            rawResponseArtifact: rawResponseArtifact)
    }

    /// The conversation of `record` as acpx holds it, for a record of its own.
    private static func conversation(_ record: SessionRecord) throws -> WireJSON {
        guard let parsed = try record.acpxRecord() else {
            throw FlowRunError("The session's record could not be written")
        }
        return parsed
    }

    /// The prompt the host made, as SwiftACP sends one. acpx sends whatever the flow gave;
    /// SwiftACP sends only content blocks it knows.
    private static func contentBlocks(_ prompt: WireJSON) throws -> [ContentBlock] {
        if let message = prompt["unserializable"]?.stringValue { throw FlowShellError(message, name: "TypeError") }
        guard case .array(let items)? = prompt["value"] else {
            throw FlowRunError("The prompt is not a list of content blocks")
        }
        return try items.enumerated().map { index, item in
            do {
                return try JSONDecoder().decode(
                    ContentBlock.self, from: Data(item.replacingLoneSurrogates().stringified.utf8))
            } catch {
                throw FlowRunError("SwiftACP cannot send prompt[\(index)] to the agent: \(item.stringified)")
            }
        }
    }
}

/// An isolated turn's conversation as it goes — acpx's `createSessionConversation` and the
/// `acpx` state its updates build — kept on a session record of SwiftACP's, which its
/// conversation model updates.
final class FlowTurnConversation: @unchecked Sendable {
    private let lock = NSLock()
    private var record: SessionRecord
    /// Whether an update or a client operation made the `acpx` state, which a record then has.
    private var touched = false

    init(_ record: SessionRecord) {
        self.record = record
    }

    /// acpx's `recordSessionUpdate`.
    func record(_ notification: SessionNotification) {
        lock.withLock {
            guard ConversationModel.recordSessionUpdate(into: &record, notification: notification) else { return }
            touched = true
        }
    }

    /// acpx's `recordClientOperation`: the conversation stamped.
    func recordClientOperation() {
        lock.withLock {
            record.updatedAt = nowISO()
            touched = true
        }
    }

    func snapshot() -> (SessionRecord, Bool) {
        lock.withLock { (record, touched) }
    }
}

/// acpx's `createPromptEventCapture`: a turn's ACP messages appended to the session's
/// event log as they come, and which of them the turn's are — unless one failed to write,
/// the first such failure the turn's.
final class FlowPromptEventCapture: @unchecked Sendable {
    struct Receipt {
        /// The first and last event of the turn, when every one was written.
        var events: (start: Int, end: Int)?
        var lastSeq: Int
        var failure: Error?
    }

    private let lock = NSLock()
    private let log: FlowSessionEventLog
    private var failure: Error?
    private var startSeq: Int?
    private var endSeq = 0

    init(log: FlowSessionEventLog) {
        self.log = log
    }

    func take(outbound: Bool, _ message: WireJSON) {
        lock.withLock {
            do {
                let seq = try log.append(outbound: outbound, message)
                startSeq = min(startSeq ?? seq, seq)
                endSeq = max(endSeq, seq)
            } catch {
                if failure == nil { failure = error }
            }
        }
    }

    func receipt() -> Receipt {
        lock.withLock {
            let events = failure == nil ? startSeq.map { (start: $0, end: endSeq) } : nil
            return Receipt(events: events, lastSeq: endSeq, failure: failure)
        }
    }
}
