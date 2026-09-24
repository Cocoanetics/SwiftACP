import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// What connecting an agent for a turn put on the wire — `initialize`, `session/load`
/// or its `session/new` fallback, the replayed selections — which acpx's formatter
/// prints before the turn: `[client] <method> (running)` in text mode, the messages
/// themselves in `--format json`.
///
/// acpx buffers these while it connects and flushes them once connected, or once
/// connecting failed (`flushConnectOutput`). When a failed `session/load` or
/// `session/resume` made it start a new session instead, that failed exchange is left
/// out (`filterRecoverableLoadFallbackOutput`): the fallback recovered from it. The
/// history a `session/load` replays never gets here: the reconnect hides it
/// (``ACPAgent/loadSession(id:cwd:mcpServers:additionalDirectories:meta:suppressReplayUpdates:)``).
final class ConnectOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(direction: JSONRPCPeer.WireDirection, body: Data)] = []

    /// The observer to tap the agent's wire with while it connects.
    var observer: RawWireTap.Observer {
        { [self] direction, body in
            lock.withLock { messages.append((direction, body)) }
        }
    }

    /// The buffered messages as acpx flushes them: `fellBack` — a new session replaced
    /// one that could not be taken back — leaves out the failed reconnect exchange.
    /// Anything else, a failed connect included, flushes everything.
    func flush(fellBack: Bool) -> [WireMessageEvent] {
        let buffered = lock.withLock { messages }
        let parsed = buffered.map { WireJSON(parsing: $0.body) }
        let failed = fellBack ? Self.failedReconnectIds(parsed.compactMap { $0 }) : []
        return zip(buffered, parsed).compactMap { entry, message in
            if !failed.isEmpty, let message, Self.belongsToFailedReconnect(message, failed) { return nil }
            return WireMessageEvent(entry.direction, entry.body)
        }
    }

    /// `session/load` and `session/resume`: acpx's `SESSION_RECONNECT_METHODS`.
    private static func isReconnect(_ method: String) -> Bool {
        method == "session/load" || method == "session/resume"
    }

    /// The ids of reconnect requests that were answered with an error. Like acpx's, the
    /// ids of both sides share one table, in the order the messages came — which lets
    /// an agent request that reuses the id hide or keep the wrong messages
    /// (openclaw/acpx#764); kept as acpx has it until upstream changes it.
    private static func failedReconnectIds(_ messages: [WireJSON]) -> Set<String> {
        var methodById: [String: String] = [:]
        var failed: Set<String> = []
        for message in messages {
            if let request = request(message) {
                methodById[request.id] = request.method
                continue
            }
            guard let response = response(message), response.hasError,
                let method = methodById[response.id], isReconnect(method)
            else { continue }
            failed.insert(response.id)
        }
        return failed
    }

    /// A failed reconnect request, or a response carrying the id of one.
    private static func belongsToFailedReconnect(_ message: WireJSON, _ failed: Set<String>) -> Bool {
        if let request = request(message), isReconnect(request.method), failed.contains(request.id) {
            return true
        }
        if let response = response(message), failed.contains(response.id) { return true }
        return false
    }

    /// acpx's `extractJsonRpcRequestInfo`: a string `method` and an id.
    private static func request(_ message: WireJSON) -> (id: String, method: String)? {
        guard let method = message["method"]?.stringValue, let id = idKey(message) else { return nil }
        return (id, method)
    }

    /// acpx's `extractJsonRpcResponseInfo`: an id, and an `error` or a `result` member.
    private static func response(_ message: WireJSON) -> (id: String, hasError: Bool)? {
        guard let id = idKey(message), message.hasMember("error") || message.hasMember("result") else {
            return nil
        }
        return (id, message.hasMember("error"))
    }

    /// acpx's `jsonRpcIdKey`: only a string or a finite number is an id, and the two
    /// never match each other — `1` is not `"1"`.
    private static func idKey(_ message: WireJSON) -> String? {
        guard let id = message["id"] else { return nil }
        switch id {
        case .string: return "s:" + id.stringified
        case .number(let value) where value.isFinite: return "n:" + id.stringified
        default: return nil
        }
    }
}
