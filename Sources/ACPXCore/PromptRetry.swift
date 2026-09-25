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
/// Fed each message as the connection reads or writes it (``observe(_:_:)``, from its
/// wire message observer): in order, and once the connection has it — where acpx's SDK
/// hands a message to its handlers. An update the agent sent before its error counts
/// before the decision, as it does in acpx.
public final class PromptSideEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var happened = false
    /// The agent's file and terminal requests being served, by id.
    private var serving: [JSONRPCID: String] = [:]

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
    public func observe(_ direction: JSONRPCPeer.WireDirection, _ message: JSONRPCMessage) {
        lock.withLock {
            guard active else { return }
            switch (direction, message) {
            case (.inbound, .notification(let note)) where note.method == "session/update":
                happened = true
            case (.inbound, .request(let request)) where Self.operations.contains(request.method):
                serving[request.id] = request.method
            case (.outbound, .response(let response)):
                if serving.removeValue(forKey: response.id) != nil { happened = true }
            case (.outbound, .errorResponse(let failure)):
                guard let id = failure.id, let method = serving.removeValue(forKey: id) else { return }
                if !Self.refusedBeforeReporting(method, failure.error) { happened = true }
            default:
                break
            }
        }
    }

    /// ``observe(_:_:)`` of a message's body, as written.
    public func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: body) else { return }
        observe(direction, message)
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
    static func refusedBeforeReporting(_ method: String, _ error: JSONRPCError) -> Bool {
        if method == "terminal/wait_for_exit" { return true }
        if error.code == -32601 || error.code == -32602 { return true }
        let details: String
        if case .object(let data)? = error.data, case .string(let text)? = data["details"] {
            details = text
        } else {
            details = error.message
        }
        if method.hasPrefix("fs/") { return pathRefusals.contains { details.hasPrefix($0) } }
        if method != "terminal/create", method != "terminal/release" {
            return details.hasPrefix(TerminalError.unknownTerminal("").description)
        }
        return false
    }
}
