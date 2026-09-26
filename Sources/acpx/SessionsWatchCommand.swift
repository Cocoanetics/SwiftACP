import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

/// `acpx [<agent>] sessions watch [-s <name>] [--cursor <cursor>]`: a session's journal,
/// replayed from after the cursor or from the start of what it retains, then followed as
/// it grows, without touching the turn running. acpx's `runSessionWatch`
/// (`cli/session-watch.ts`, 0.19.1). A signal ends it, quietly.
enum SessionsWatchCommand {
    static func run(_ context: CommandContext) throws -> Int32 {
        let flags = try context.globalFlags()
        let agent = try Flags.resolveAgentInvocation(context.explicitAgent, flags, config: context.config)
        let name = try context.options.string("name").map(parseSessionName)
        // An open session, else a closed one, as acpx finds the session to watch.
        guard let record = SessionStore.findSession(
                agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: false)
            ?? SessionStore.findSession(
                agentCommand: agent.agentCommand, cwd: agent.cwd, name: name, includeClosed: true)
        else {
            throw CLIError(SessionsCommand.missingScopedSessionMessage(agent: agent, name: name))
        }
        let recordId = record.acpxRecordId
        let maxSegments = record.eventLog.maxSegments > 0 ? record.eventLog.maxSegments : DEFAULT_EVENT_MAX_SEGMENTS
        let cursor = context.options.string("cursor")
        let renderer = WatchRenderer(options: renderOptions(flags))
        try runBlocking {
            let owner = WatchOwner(recordId: recordId)
            let watching = Task {
                try await SessionJournal.watch(
                    recordId: recordId, maxSegments: maxSegments, cursor: cursor,
                    continueWatching: { try await owner.shouldContinue(pendingRequestId: $0) },
                    onEvent: { renderer.render($0) })
            }
            let listening = Interrupts.listen { _ in watching.cancel() }
            defer { listening.stop() }
            let outcome = await watching.result
            await owner.disconnect()
            try outcome.get()
        }
        return ExitCodes.success
    }
}

/// acpx's `watchRenderer`: each event as `sessions watch` shows it. JSON output is the
/// events themselves. Text and quiet output render each turn through a formatter of its
/// own, begun at the turn's start, which writes no color: acpx's writes to a buffer, not a
/// terminal. Text output also marks each turn's start and result, with their cursors.
final class WatchRenderer: @unchecked Sendable {
    private let options: RenderOptions
    private let out: @Sendable (String) -> Void
    private let err: @Sendable (String) -> Void
    private var sanitizer: JSONMessageSanitizer
    private var formatter: OutputRenderer

    init(
        options: RenderOptions, out: @escaping @Sendable (String) -> Void = Console.out,
        err: @escaping @Sendable (String) -> Void = Console.err
    ) {
        self.options = options
        self.out = out
        self.err = err
        sanitizer = JSONMessageSanitizer(suppressReads: options.suppressReads, partialHistory: true)
        formatter = OutputRenderer(options: RenderOptions(format: options.format), out: out, err: err, color: false)
    }

    func render(_ event: SessionJournal.WatchEvent) {
        if case .turnStarted = event.kind {
            sanitizer = JSONMessageSanitizer(suppressReads: options.suppressReads, partialHistory: true)
            formatter = OutputRenderer(
                options: RenderOptions(format: options.format), out: out, err: err, color: false)
        }
        if options.format == .json {
            var shown: WireJSON?
            if case .message(_, let message) = event.kind { shown = sanitizer.sanitize(message, direction: nil) }
            out(event.json(message: shown).stringified + "\n")
            return
        }
        switch event.kind {
        case .message(_, let message):
            let sanitized = sanitizer.sanitize(message, direction: nil)
            // The turn's result says how its prompt ended: text output shows that, not the answer.
            if options.format == .quiet || OutputRenderer.promptStopReason(sanitized) == nil {
                formatter.journalMessage(sanitized)
            }
        case .turnStarted(let requestId):
            if options.format != .quiet { out("\n[\(requestId)] started cursor=\(event.cursor)\n") }
        case let .turnResult(requestId, result):
            formatter.flushJournalTurn()
            if options.format != .quiet { out(Self.resultLine(requestId, result, cursor: event.cursor)) }
        }
    }

    /// acpx's `watchLifecycleLine` for a result: its status, then the error's message or
    /// the stop reason, when there is one.
    static func resultLine(_ requestId: String, _ result: WireJSON, cursor: String) -> String {
        let status = result["status"]?.stringValue ?? ""
        let detail = status == "failed" ? result["error"]?["message"]?.stringValue : result["stopReason"]?.stringValue
        let shown = detail.map { $0.isEmpty ? "" : ": \($0)" } ?? ""
        return "\n[\(requestId)] \(status)\(shown) cursor=\(cursor)\n"
    }
}

/// Whether acpxd holds the session a watch follows, where acpx's `continueWatching`
/// (`session/watch.ts`) reads the session's queue owner. The daemon is asked on one
/// connection, kept while it answers.
actor WatchOwner {
    private let recordId: String
    /// The turn a look found started and not ended, with nothing holding the session.
    private var missingRequest: String?
    private var proxy: MCPServerProxy?

    init(recordId: String) {
        self.recordId = recordId
    }

    /// acpx's `continueWatching`, once a watch has caught up with the journal:
    /// - while acpxd holds the session, as acpx's live owner does, the watch goes on;
    /// - a daemon from before it could say so is one from before the journal:
    ///   `WATCH_OWNER_UNSUPPORTED`;
    /// - with nothing holding the session, a turn started and not ended gets one more look,
    ///   and is `WATCH_OUTCOME_UNKNOWN` at a second without its result; with no such turn,
    ///   the watch goes on while the session is open.
    func shouldContinue(pendingRequestId: String?) async throws -> Bool {
        try decide(await hold(), pendingRequestId: pendingRequestId)
    }

    /// What ``shouldContinue(pendingRequestId:)`` makes of what the daemon said.
    func decide(_ hold: DaemonClient.SessionHold, pendingRequestId: String?) throws -> Bool {
        switch hold {
        case .unknown:
            throw SessionJournalError(
                code: "WATCH_OWNER_UNSUPPORTED",
                message: "This running session owner predates passive watching. Let it expire when idle or "
                    + "explicitly close the session before starting new work.")
        case .held, .unreachable:
            missingRequest = nil
            return true
        case .notHeld:
            if let pendingRequestId, pendingRequestId == missingRequest {
                throw SessionJournalError(
                    code: "WATCH_OUTCOME_UNKNOWN",
                    message: "Session owner ended without a settled result for request \(pendingRequestId); its "
                        + "outcome is unknown. Resume watching from the last cursor after recovery, and do not "
                        + "automatically replay the prompt.")
            }
            missingRequest = pendingRequestId
            if pendingRequestId != nil { return true }
            guard let record = SessionStore.loadRecord(recordId), record.acpxRecordId == recordId else {
                throw NoSessionError("Session not found: \(recordId)")
            }
            return record.closed != true
        }
    }

    func disconnect() async {
        await proxy?.disconnect()
        proxy = nil
    }

    /// What acpxd says of the session. A daemon whose process runs but does not answer is
    /// taken to hold it, as acpx takes an owner whose process lives.
    private func hold() async -> DaemonClient.SessionHold {
        guard let holder = DaemonClient.liveHolder() else {
            await disconnect()
            return .notHeld
        }
        if proxy == nil {
            proxy = await DaemonClient.tryConnect(DaemonClient.endpoint(of: holder), configure: { _ in })
        }
        guard let proxy else { return .unreachable }
        let hold = await DaemonClient.sessionHold(on: proxy, sessionId: recordId)
        if hold == .unreachable { await disconnect() }
        return hold
    }
}
