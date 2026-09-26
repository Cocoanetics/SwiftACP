import ACPXCore
import Foundation
import SwiftACP

/// What an ACP node's turn said: acpx's `createQuietCaptureOutput`, its quiet output
/// formatter (`QuietOutputFormatter`, `src/cli/output/output.ts`) fed every ACP message of
/// the turn, its standard output kept, and read back trimmed as the node's raw text.
///
/// The formatter's standard error is acpx's own: a permission notice, and the prompt
/// response's token usage and cost, still go there (`errorOutput`).
final class FlowQuietCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let errorOutput: @Sendable (String) -> Void
    private var chunks: [[UInt16]] = []
    private var finished = false
    private var outputWritten = false
    private var metadataFlushed = false
    /// What the formatter wrote to its standard output.
    private var written: [UInt16] = []
    private var readySessionId: String?

    init(errorOutput: @escaping @Sendable (String) -> Void) {
        self.errorOutput = errorOutput
    }

    /// The formatter's `onAcpMessage`.
    func take(_ message: WireJSON) {
        var errors: [String] = []
        lock.withLock {
            if let notice = Self.permissionNotice(message) {
                errors.append("[acpx] permission: \(Self.oneLine(notice))\n")
                return
            }
            if let text = Self.agentMessageText(message) {
                if !finished { chunks.append(text) }
                return
            }
            guard Self.promptStopReason(message) != nil else { return }
            if !finished {
                finished = true
                flushBufferedOutput(allowEmpty: true)
            }
            if !metadataFlushed {
                metadataFlushed = true
                if let result = message["result"], case .object = result {
                    if let line = QuietMetadata.usageLine(result["usage"]) { errors.append(line + "\n") }
                    if let line = QuietMetadata.costLine(result["cost"]) { errors.append(line + "\n") }
                }
            }
        }
        for line in errors { errorOutput(line) }
    }

    /// The formatter's `setContext`, which the capture takes the session's id from.
    func sessionReady(_ sessionId: String) {
        lock.withLock { readySessionId = sessionId }
    }

    /// The session the turn set up, once it did.
    var sessionId: String? { lock.withLock { readySessionId } }

    /// The formatter's `flush`, which the turn ends with however it went.
    func flush() {
        lock.withLock { flushBufferedOutput(allowEmpty: false) }
    }

    /// The capture's `read`: what was written, trimmed.
    func read() -> [UInt16] {
        lock.withLock { SessionRecordParser.javaScriptTrimmed(written) }
    }

    private func flushBufferedOutput(allowEmpty: Bool) {
        let text = Array(chunks.joined())
        chunks = []
        if text.isEmpty, !allowEmpty || outputWritten { return }
        outputWritten = true
        written += text.last == 0x0A ? text : text + [0x0A]
    }

    /// `notice.replace(/\r\n?|\n/g, " ")`.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// acpx's `parsePermissionNotice`: a response carrying `result._meta.acpx.permissionNotice`.
    private static func permissionNotice(_ message: WireJSON) -> String? {
        guard message.hasMember("id"), message.hasMember("result"), case .object? = message["result"],
            case .object? = message["result"]?["_meta"], case .object? = message["result"]?["_meta"]?["acpx"]
        else { return nil }
        return message["result"]?["_meta"]?["acpx"]?["permissionNotice"]?.stringValue
    }

    /// The text of an `agent_message_chunk` of text, as acpx's
    /// `extractSessionUpdateNotification` takes one: a `session/update` notification with
    /// a string `sessionId` and an update carrying text content.
    private static func agentMessageText(_ message: WireJSON) -> [UInt16]? {
        guard message["method"] == .text("session/update"), !message.hasMember("id"),
            let params = message["params"], case .object = params, case .string(let sessionId)? = params["sessionId"],
            !sessionId.isEmpty, let update = params["update"], case .object = update,
            update["sessionUpdate"] == .text("agent_message_chunk"), let content = update["content"],
            case .object = content, content["type"] == .text("text"), case .string(let text)? = content["text"]
        else { return nil }
        return text
    }

    /// acpx's `parsePromptStopReason`: a response whose result has a string `stopReason`.
    private static func promptStopReason(_ message: WireJSON) -> String? {
        guard message.hasMember("id"), message.hasMember("result"), case .object? = message["result"] else {
            return nil
        }
        return message["result"]?["stopReason"]?.stringValue
    }
}
