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
/// An attempt a fresh launch may retry holds its error responses back in either case
/// (`holdingErrors`): a retried attempt did not fail the turn, and ``finish(showingHeld:)``
/// drops them. The prompt's failure is the last message of its attempt, so holding it
/// back moves it nowhere.
final class TurnWireFeed: @unchecked Sendable {
    private let streamWire: Bool
    private let holdingErrors: Bool
    private let feed: AsyncStream<WireMessageEvent>.Continuation
    private let forwarder: Task<Void, Never>
    private let lock = NSLock()
    private var held: [WireMessageEvent] = []

    init(streamWire: Bool, holdingErrors: Bool = false, logger: String, to clientSession: Session?) {
        let (messages, feed) = AsyncStream<WireMessageEvent>.makeStream()
        self.streamWire = streamWire
        self.holdingErrors = holdingErrors || !streamWire
        self.feed = feed
        forwarder = Task {
            for await message in messages {
                await clientSession?.sendLogNotification(
                    LogMessage(level: .info, logger: logger, data: toJSONValue(message)))
            }
        }
    }

    /// A message crossed the wire.
    func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) {
        if holdingErrors, direction == .inbound, Self.isErrorResponse(body) {
            lock.withLock { held.append(WireMessageEvent(direction, body)) }
        } else if streamWire {
            feed.yield(WireMessageEvent(direction, body))
        }
    }

    /// The turn's exchange is over: send what was held back — unless `showingHeld` is
    /// false, for an attempt that is retried — and return once everything has gone out.
    func finish(showingHeld: Bool = true) async {
        if showingHeld {
            for message in lock.withLock({ held }) { feed.yield(message) }
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
