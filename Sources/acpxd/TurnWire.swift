import ACPXCore
import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP

/// The errors a turn's exchange shows, as acpx's `AcpErrorTracker` follows them: what
/// connecting put on the wire, then the turn itself, each prompt attempt afresh. When
/// the turn fails, it says which error the failure is, and so whether the output
/// already shows it. Fed from the transport's tasks, so lock-protected.
final class TurnErrorWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = AcpErrorTracker()

    func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        guard let message = WireJSON(parsing: body) else { return }
        lock.withLock { tracker.observe(message, inbound: direction == .inbound) }
    }

    func observe(_ events: [WireMessageEvent]) {
        for event in events {
            observe(event.wireDirection == "outbound" ? .outbound : .inbound, Data(event.wireLine.utf8))
        }
    }

    /// A prompt attempt starts, once its agent is connected (acpx's `runPromptAttempt`).
    func reset() {
        lock.withLock { tracker.reset() }
    }

    /// The error the stream showed that `error` is, if it showed one.
    func match(_ error: Error) -> AcpErrorPayload? {
        lock.withLock { tracker.match(failureText: TurnFailure.message(of: error)) }
    }
}

/// What of a turn's exchange goes to the calling client, as log notifications. With
/// `streamWire` (`--format json`) that is every message as it crosses the wire, in
/// order, as acpx prints them. Otherwise it is only the agent's error responses, which
/// acpx's text output shows as errors: they wait for ``finish()``, so the updates before
/// them, which reach the client another way, are out first.
///
/// An attempt a fresh launch may retry is `provisional` until the agent answers it with
/// anything but an error — an update, a request of its own, a result (``agentAnswered``).
/// Until then, JSON output holds all of its messages back, and a retried attempt's are
/// dropped by ``finish(showingHeld:)``: a retried attempt did not happen, as far as the
/// output goes. Once the agent answers, what was held goes out, and the rest streams.
final class TurnWireFeed: @unchecked Sendable {
    private let streamWire: Bool
    private let provisional: Bool
    private let feed: AsyncStream<WireMessageEvent>.Continuation
    private let forwarder: Task<Void, Never>
    private let lock = NSLock()
    /// Text output's error responses, until the turn's exchange is over.
    private var held: [WireMessageEvent] = []
    /// JSON output's messages of a provisional attempt the agent has not answered yet.
    private var pending: [WireMessageEvent] = []
    private var answered = false

    init(streamWire: Bool, provisional: Bool = false, logger: String, to clientSession: Session?) {
        let (messages, feed) = AsyncStream<WireMessageEvent>.makeStream()
        self.streamWire = streamWire
        self.provisional = provisional
        self.feed = feed
        forwarder = Task {
            for await message in messages {
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: logger, data: toJSONValue(message)))
            }
        }
    }

    /// Whether the agent has answered the attempt with anything but an error. An attempt
    /// it answered has reached it, and is never sent again.
    var agentAnswered: Bool { lock.withLock { answered } }

    /// A message crossed the wire.
    func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        let message = WireMessageEvent(direction, body)
        let isError = direction == .inbound && Self.isErrorResponse(body)
        lock.withLock {
            if direction == .inbound, !isError, !answered {
                answered = true
                for earlier in pending { feed.yield(earlier) }
                pending = []
            }
            if !streamWire {
                if isError { held.append(message) }
            } else if provisional, !answered {
                pending.append(message)
            } else {
                feed.yield(message)
            }
        }
    }

    /// Text output's error responses held so far, taken to go out now: a failed
    /// attempt's, which the prompt's retry shows before what follows it.
    func takeHeld() -> [WireMessageEvent] {
        lock.withLock {
            defer { held = [] }
            return held
        }
    }

    /// The turn's exchange is over: send what was held back — unless `showingHeld` is
    /// false, for an attempt that is retried — and return once everything has gone out.
    func finish(showingHeld: Bool = true) async {
        if showingHeld {
            for message in lock.withLock({ pending + held }) { feed.yield(message) }
        }
        feed.finish()
        await forwarder.value
    }

    /// A JSON-RPC error response: an `error` member, and no `method`.
    static func isErrorResponse(_ body: Data) -> Bool {
        guard let message = WireJSON(parsing: body) else { return false }
        return message.hasMember("error") && !message.hasMember("method")
    }
}

extension WireMessageEvent {
    init(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        self.init(
            wireDirection: direction == .outbound ? "outbound" : "inbound",
            wireLine: String(decoding: body, as: UTF8.self))
    }
}

/// What a turn's event subscription carries, relayed to the calling client as the turn
/// goes (``ACPXDaemonBackend/relay(_:of:as:into:to:onAnswered:)``), in phases: at a
/// failed attempt the relay hands over to what follows at one point in the events, so
/// that the attempt's own go out first, then its error, then the rest.
actor TurnRelay {
    typealias Relaying = @Sendable (AsyncStream<ConnectionEvent>) async -> String

    private let connection: ACPAgentConnection
    private let sessionId: SessionId
    private let logger: String
    private let clientSession: Session?
    private let relaying: Relaying
    private var subscription: UUID
    /// The latest phase's relay, which waits for the phases before it; each returns the
    /// agent's message text of the phases so far.
    private var consumer: Task<String, Never>

    /// Subscribe to `connection`'s events — before the turn sends anything, so that none
    /// is missed — and relay them with `relaying`.
    init(
        connection: ACPAgentConnection, sessionId: SessionId, logger: String, to clientSession: Session?,
        relaying: @escaping Relaying
    ) async {
        self.connection = connection
        self.sessionId = sessionId
        self.logger = logger
        self.clientSession = clientSession
        self.relaying = relaying
        let (subscription, stream) = await connection.makeEventSubscription()
        self.subscription = subscription
        consumer = Task { await relaying(stream) }
    }

    /// End the phase at one point in the events — what the connection has read of the
    /// session's updates handed on first — and relay what comes after once the phase's
    /// events, and then `held`, have gone out.
    func handOver(showing held: [WireMessageEvent]) async {
        await connection.waitForSessionUpdatesHandled(sessionId: sessionId)
        let (next, stream) = await connection.replaceEventSubscription(subscription)
        subscription = next
        let (previous, relaying, clientSession, logger) = (consumer, relaying, clientSession, logger)
        consumer = Task {
            let earlier = await previous.value
            for message in held {
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: logger, data: toJSONValue(message)))
            }
            return earlier + (await relaying(stream))
        }
    }

    /// End the subscription: nothing more is relayed.
    func end() async {
        await connection.endSubscription(subscription)
    }

    /// The agent's message text for the turn, once everything relayed has gone out.
    func text() async -> String {
        await consumer.value
    }
}
