import Foundation
import JSONFoundation
import SwiftACP

/// acpx's retry of a failed prompt under `--prompt-retries` (`preparePromptRetry`): the
/// prompt goes again, after a pause, while it fails the way a passing fault does and
/// the turn has had no effect yet (see ``PromptSideEffects``).
public enum PromptRetry {
    /// acpx's `isRetryablePromptError`: the agent's ACP error `-32603` (internal error,
    /// which usually wraps a model API's failure) or `-32700` (parse error). Nothing
    /// else — not a timeout, nor any failure of the client's own.
    public static func isRetryable(_ error: Error) -> Bool {
        guard let rpc = error as? JSONRPCErrorBody else { return false }
        return rpc.code == -32603 || rpc.code == -32700
    }

    /// The pause before the retry that follows attempt `attempt` (from 0):
    /// `min(1000 × 2^attempt, 10000)` milliseconds.
    public static func delayMilliseconds(afterAttempt attempt: Int) -> Int {
        attempt >= 4 ? 10_000 : min(1_000 << attempt, 10_000)
    }

    /// acpx's `emitPromptRetryNotice`: `retry` of `maxRetries` follows after `delay`.
    public static func notice(for error: Error, delayMilliseconds delay: Int, retry: Int, maxRetries: Int) -> String {
        "[acpx] prompt failed (\(TurnFailure.message(of: error))), retrying in \(delay)ms "
            + "(attempt \(retry)/\(maxRetries))"
    }
}

/// acpx's `promptTurnHadSideEffects`: whether a prompt's turn has already done
/// something a second attempt would do again, so it is not retried. acpx counts every
/// session update and every client operation its handlers report: a file or terminal
/// request of the agent's, reported once it passes the handler's checks, and the notice
/// of a refused permission. A permission question alone is not one.
///
/// Fed each message as it crosses the wire (``observe(_:_:)``, from the raw tap): in read
/// order, and ahead of the prompt's answer — so an update the agent sent before its
/// error, or in the same read, counts before the decision, as it does in acpx.
public final class PromptSideEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var happened = false
    /// The agent's file and terminal requests being served, by id as it was written.
    private var serving: [String: String] = [:]

    public init() {}

    /// The turn starts: from here on, what happens counts (acpx's `promptTurnActive`).
    public func begin() {
        lock.withLock { active = true }
    }

    /// The turn is over: nothing counts any more.
    public func end() {
        lock.withLock {
            active = false
            serving = [:]
        }
    }

    /// Whether the turn has had an effect: one happened, or a request that is one is
    /// still being served (acpx reports a `terminal/wait_for_exit` only once it is over).
    public var any: Bool {
        lock.withLock { happened || serving.values.contains { $0 != "terminal/wait_for_exit" } }
    }

    /// A client operation the connection reported — a permission notice.
    public func clientOperation() {
        lock.withLock { if active { happened = true } }
    }

    /// Look at a message as it crossed the wire.
    public func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        guard lock.withLock({ active }), let message = WireJSON(parsing: body) else { return }
        let method = message["method"]?.stringValue
        let id = message["id"]?.stringified
        lock.withLock {
            switch (direction, method, id) {
            case (.inbound, "session/update"?, nil):
                happened = true
            case (.inbound, let method?, let id?) where Self.operations.contains(method):
                serving[id] = method
            case (.outbound, nil, let id?):
                guard let method = serving.removeValue(forKey: id) else { return }
                if let error = message["error"] {
                    if !Self.refusedBeforeReporting(method, error) { happened = true }
                } else {
                    happened = true
                }
            default:
                break
            }
        }
    }

    /// The agent's requests acpx's file-system and terminal handlers report as
    /// operations.
    static let operations: Set<String> = [
        "fs/read_text_file", "fs/write_text_file", "terminal/create", "terminal/output",
        "terminal/wait_for_exit", "terminal/kill", "terminal/release"
    ]

    /// SwiftACP's refusals of a file request whose path acpx refuses before reporting
    /// the operation (`resolvePathWithinRoot`).
    static let pathRefusals = ["Path must be absolute: ", "Path is outside allowed cwd subtree: "]

    /// Whether `method` was refused where acpx reports no operation: a method it does
    /// not serve, params it does not take, a path it will not resolve, or a terminal it
    /// does not know (for all but `terminal/release`, which reports first). A
    /// `terminal/wait_for_exit` is reported only once it is answered.
    static func refusedBeforeReporting(_ method: String, _ error: WireJSON) -> Bool {
        if method == "terminal/wait_for_exit" { return true }
        if case .number(let code)? = error["code"], code == -32601 || code == -32602 { return true }
        let details = error["data"]?["details"]?.stringValue ?? error["message"]?.stringValue ?? ""
        if method.hasPrefix("fs/") { return pathRefusals.contains { details.hasPrefix($0) } }
        if method != "terminal/create", method != "terminal/release" {
            return details.hasPrefix(TerminalError.unknownTerminal("").description)
        }
        return false
    }
}
