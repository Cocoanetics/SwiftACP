import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

// What a turn is asked to do, checked before it queues: a malformed request is its caller's
// mistake, not something to find out after waiting out another turn. Split from
// `ACPXDaemonBackend+Prompt.swift` to keep it inside the 500-line limit.
extension ACPXDaemonBackend {
    /// A turn's retries and timeout, as acpx's queue owner takes them: it refuses a negative
    /// retry count, and takes a timeout that is not positive as none. One longer than a timer
    /// takes is refused, as acpx's CLI refuses it — the owner's timer would fire at once — and
    /// so is a TTL, as acpx's CLI refuses `--ttl` past it.
    static func checkedLimits(_ limits: PromptLimits?) throws -> (retries: Int, timeout: Int?) {
        let retries = limits?.promptRetries ?? 0
        guard retries >= 0 else { throw DaemonError.invalidPromptRetries(retries) }
        let timeout = limits?.timeoutMs.flatMap { $0 > 0 ? $0 : nil }
        if let timeout, timeout > JavaScriptNumber.maxTimerDelayMs { throw DaemonError.invalidTimeout(timeout) }
        if let ttl = limits?.ttlMs, ttl > JavaScriptNumber.maxTimerDelayMs { throw DaemonError.invalidTTL(ttl) }
        return (retries, timeout)
    }

    /// A turn's prompt, from its text and its blocks or its content: a malformed block fails
    /// at once. The daemon's transport has a ceiling, so the request's size is capped here — a
    /// direct client has nothing in the way.
    static func promptContent(text: String, blocks: [PromptBlock]?, content: [JSONValue]?) throws -> [ContentBlock] {
        guard let content else {
            return try PromptBlock.contentBlocks(text: text, blocks: blocks, requestLimit: PromptBlock.maxRequestBytes)
        }
        guard blocks == nil else {
            throw PromptContent.ValidationError(message: "pass the prompt's blocks or its content, not both")
        }
        return try PromptContent.contentBlocks(text: text, content: content, requestLimit: PromptBlock.maxRequestBytes)
    }
}
