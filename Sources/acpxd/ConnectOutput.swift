import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP

/// What connecting an agent for a turn put on the wire — `initialize`, `session/load`
/// or its `session/new` fallback, the replayed selections — which acpx's formatter
/// prints before the turn: `[client] <method> (running)` in text mode, the messages
/// themselves in `--format json`.
///
/// acpx buffers these while it connects and flushes them once connected
/// (`flushConnectOutput`). When a failed `session/load` or `session/resume` made it
/// start a new session instead, that failed exchange is left out
/// (`filterRecoverableLoadFallbackOutput`): the fallback recovered from it.
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
    func flush(fellBack: Bool) -> [WireMessageEvent] {
        let buffered = lock.withLock { messages }
        let failed = fellBack ? Self.failedReconnectIds(buffered.map(\.body)) : []
        return buffered.compactMap { direction, body in
            if !failed.isEmpty, let message = WireJSON(parsing: body), let id = Self.idKey(message),
                failed.contains(id), message["method"].map(Self.isReconnect) ?? true {
                return nil
            }
            return WireMessageEvent(direction, body)
        }
    }

    /// `session/load` and `session/resume`: acpx's `SESSION_RECONNECT_METHODS`.
    private static func isReconnect(_ method: WireJSON) -> Bool {
        method.stringValue == "session/load" || method.stringValue == "session/resume"
    }

    /// The ids of reconnect requests that were answered with an error.
    private static func failedReconnectIds(_ bodies: [Data]) -> Set<String> {
        var methodById: [String: WireJSON] = [:]
        var failed: Set<String> = []
        for message in bodies.compactMap({ WireJSON(parsing: $0) }) {
            guard let id = idKey(message) else { continue }
            if let method = message["method"] {
                methodById[id] = method
            } else if message.hasMember("error"), let method = methodById[id], isReconnect(method) {
                failed.insert(id)
            }
        }
        return failed
    }

    /// A message's JSON-RPC id, as printed — so `1` and `"1"` stay apart.
    private static func idKey(_ message: WireJSON) -> String? {
        guard let id = message["id"], id != .null else { return nil }
        return id.stringified
    }
}
