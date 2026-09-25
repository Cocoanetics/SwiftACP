import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// How the renderer reports a failure: a failed turn as acpx's formatters report its
// queue owner's error, and what the stream already showed of it. Split from
// `OutputRenderer.swift` to keep each file inside the 500-line limit.
extension OutputRenderer {
    /// A prompt attempt starts: the errors shown before it no longer say how it fails
    /// (acpx resets its tracker as each attempt starts).
    func promptAttemptStarts() {
        lock.lock()
        defer { lock.unlock() }
        shownErrors.reset()
    }

    /// A turn that needed a permission question nobody could be asked fails once over,
    /// and acpx's queue owner reports it (`emitQueueOwnerError`): text output as an
    /// `[error]` section, JSON output as its error line naming the session. Neither
    /// prints when the stream already shows the client's refusal saying the same, as a
    /// refused write's does. Quiet output is ``permissionExitCode(_:quiet:queueDetail:)``'s.
    func permissionPromptUnavailable(sessionId: String) {
        let message = FileSystemPermissionError.promptUnavailable.description
        guard !showedFailure(message) else { return }
        switch options.format {
        case .text:
            renderError(
                code: "PERMISSION_PROMPT_UNAVAILABLE", message, detailCode: "QUEUE_RUNTIME_PROMPT_FAILED",
                origin: "runtime")
        case .json:
            lock.withLock {
                out(JSONErrorLine.make(
                    outputCode: "PERMISSION_PROMPT_UNAVAILABLE", detailCode: "QUEUE_RUNTIME_PROMPT_FAILED",
                    origin: "runtime", message: message, sessionId: sessionId) + "\n")
            }
        case .quiet:
            break
        }
    }

    /// Whether the stream has already shown the failure described by `failureText`:
    /// acpx then prints nothing more for it.
    func showedFailure(_ failureText: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shownErrors.match(failureText: failureText) != nil
    }

    /// Report a failure the stream did not show, as the JSON-RPC error line acpx's
    /// top-level handler prints (session id `unknown`: it has no session to name).
    func jsonFailure(outputCode: String, detailCode: String? = nil, origin: String = "cli", message: String) {
        lock.lock()
        defer { lock.unlock() }
        out(JSONErrorLine.make(
            outputCode: outputCode, detailCode: detailCode, origin: origin, message: message,
            sessionId: "unknown") + "\n")
    }

    /// Report a failed turn the way acpx's formatters report its queue owner's error
    /// (`emitQueueOwnerError`): text and JSON output add nothing when the stream already
    /// shows it; quiet output always prints its one line — after what the agent had
    /// said, which a failure flushes.
    func turnFailed(_ event: TurnFailedEvent) {
        let acp = event.acp.flatMap(AcpErrorPayload.init)
        switch options.format {
        case .text:
            guard !event.shown else { return }
            renderError(
                code: event.outputCode, event.message, acp: acp, detailCode: event.detailCode,
                origin: event.origin ?? "runtime")
        case .quiet:
            lock.lock()
            defer { lock.unlock() }
            let text = quietChunks.joined()
            quietChunks = []
            if !text.isEmpty { out(text.hasSuffix("\n") ? text : text + "\n") }
            let qualifier = event.detailCode.map { "\(event.outputCode) \($0)" } ?? event.outputCode
            let line = (acp?.details ?? event.message)
                .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            err("[acpx] error: \(qualifier) \(line)\n")
        case .json:
            guard !event.shown else { return }
            lock.lock()
            defer { lock.unlock() }
            out(JSONErrorLine.make(
                outputCode: event.outputCode, detailCode: event.detailCode, origin: event.origin ?? "runtime",
                message: event.message, retryable: event.retryable, sessionId: event.sessionId, acp: acp) + "\n")
        }
    }
}
