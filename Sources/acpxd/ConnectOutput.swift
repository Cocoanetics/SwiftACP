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
/// out (`filterBufferedConnectOutput`): the fallback recovered from it. The
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
        let hidden = fellBack ? Self.failedReconnectExchanges(buffered) : []
        return buffered.enumerated().compactMap { index, entry in
            hidden.contains(index) ? nil : WireMessageEvent(entry.direction, entry.body)
        }
    }

    /// `session/load` and `session/resume`: acpx's `SESSION_RECONNECT_METHODS`.
    private static func isReconnect(_ method: String) -> Bool {
        method == "session/load" || method == "session/resume"
    }

    /// acpx 0.19.3's `filterBufferedConnectOutput` (#778, for our openclaw/acpx#764): the
    /// positions of each outbound `session/load` or `session/resume` request answered by
    /// an inbound error, and of that error. The two are paired by direction and exactly:
    /// an inbound response settles the request pending under its id, whatever it says,
    /// and only an error hides the pair. The agent's own requests, and the client's
    /// answers to them, are never taken for either.
    private static func failedReconnectExchanges(
        _ messages: [(direction: JSONRPCPeer.WireDirection, body: Data)]
    ) -> Set<Int> {
        var pending: [String: Int] = [:]
        var hidden: Set<Int> = []
        for (index, entry) in messages.enumerated() {
            guard let message = WireJSON(parsing: entry.body), let id = idKey(message) else { continue }
            if entry.direction == .outbound, let method = message["method"]?.stringValue, isReconnect(method) {
                pending[id] = index
            } else if entry.direction == .inbound, message.hasMember("result") || message.hasMember("error") {
                if let request = pending[id], message.hasMember("error") {
                    hidden.insert(request)
                    hidden.insert(index)
                }
                pending[id] = nil
            }
        }
        return hidden
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
