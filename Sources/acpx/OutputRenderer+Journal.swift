import ACPXCore
import Foundation
import SwiftACP

// Rendering an ACP message read back from a session's journal, as acpx's text and quiet
// formatters render a message they are handed (`onAcpMessage`): how `sessions watch`
// shows a turn. Split from `OutputRenderer.swift` to keep that file inside the 500-line
// limit.
extension OutputRenderer {
    /// acpx's `onAcpMessage`. In text output:
    /// - a permission notice is `[permission] <notice>`;
    /// - a session update is rendered as it would be live;
    /// - a request of any other method than the prompt's, its cancel and the updates is
    ///   `[client] <method> (running)`;
    /// - a prompt's answer ends the turn's output;
    /// - an error response is `[error] RUNTIME: <details>`.
    ///
    /// Quiet output keeps the agent's text until the prompt's answer, writes the notices to
    /// stderr, and nothing else.
    func journalMessage(_ message: WireJSON) {
        if let notice = Self.permissionNotice(message) {
            clientOperation(
                ClientOperation(method: ClientOperation.requestPermission, status: .completed, summary: notice))
            return
        }
        if let update = Self.sessionUpdate(message) {
            render(update)
            return
        }
        if let method = message["method"]?.stringValue {
            if !["session/prompt", "session/cancel", "session/update"].contains(method) { clientOperation(method) }
            return
        }
        if let stopReason = Self.promptStopReason(message) {
            finish(stopReason: StopReason(rawValue: stopReason))
            if let result = message["result"] { promptMetadata(usage: result["usage"], cost: result["cost"]) }
            return
        }
        if let summary = Self.errorSummary(message) { renderError(code: "RUNTIME", summary) }
    }

    /// acpx's formatter `flush()`, which `sessions watch` calls at a turn's result: text
    /// output ends the line left open, and quiet output writes what the agent said that it
    /// has not written yet — nothing, when that is nothing.
    func flushJournalTurn() {
        switch options.format {
        case .text:
            flushText()
        case .quiet:
            lock.withLock {
                let text = quietChunks.joined()
                quietChunks = []
                if !text.isEmpty { out(text.hasSuffix("\n") ? text : text + "\n") }
            }
        case .json:
            break
        }
    }

    /// acpx's `parsePermissionNotice`: a response whose result carries
    /// `_meta.acpx.permissionNotice`.
    static func permissionNotice(_ message: WireJSON) -> String? {
        guard message.hasMember("id"), let result = message["result"], case .object = result else { return nil }
        return result["_meta"]?["acpx"]?["permissionNotice"]?.stringValue
    }

    /// acpx's `parsePromptStopReason`: a response whose result has a `stopReason`.
    static func promptStopReason(_ message: WireJSON) -> String? {
        guard message.hasMember("id"), let result = message["result"], case .object = result else { return nil }
        return result["stopReason"]?.stringValue
    }

    /// acpx's `extractSessionUpdateNotification`: a `session/update` naming its session,
    /// whose update reads as one.
    static func sessionUpdate(_ message: WireJSON) -> SessionUpdate? {
        guard message["method"]?.stringValue == "session/update", let params = message["params"],
              case .object = params, params["sessionId"]?.stringValue != nil,
              let notification = try? JSONDecoder().decode(
                SessionNotification.self, from: Data(params.stringified.utf8))
        else { return nil }
        return notification.update
    }

    /// acpx's `parseJsonRpcErrorSummary`: an error response's `data.details`, trimmed, when
    /// there are any, else its message.
    static func errorSummary(_ message: WireJSON) -> String? {
        guard let error = message["error"], case .object = error, let fallback = error["message"]?.stringValue
        else { return nil }
        let details = error["data"]?["details"]?.stringValue?.javaScriptTrimmed ?? ""
        return details.isEmpty ? fallback : details
    }
}
