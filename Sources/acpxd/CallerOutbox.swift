import Foundation
import JSONFoundation
import SwiftMCP

/// What acpxd sends the client of one call — a turn's updates, its answer and its end — without
/// waiting for the client to read it, as acpx's queue owner writes an observer's output
/// (`QueueSocketOutput`, openclaw/acpx#723). A turn goes on however slowly its CLI reads, or if
/// it reads nothing, and the prompt queued after it with it.
///
/// The messages go out in order, one at a time, from the outbox's own task, and the call's
/// result follows them (``flush()``). Each is held as the frame it goes out as, so what the
/// bounds count is what is held. What the client has yet to be sent — what waits, and the
/// message going out, which the transport holds until it has gone — is bounded as acpx bounds
/// an observer's output: 64 MiB for a call, 256 MiB for all calls, 64 calls with output unsent.
/// Past a bound, the client is disconnected (``Session/disconnect()``), as acpx destroys that
/// observer's socket, and nothing more goes to it; the turn goes on. A client that leaves its
/// output unread for ten seconds is disconnected by the transport
/// (`TCPBonjourTransport.sendStallTimeout`), as acpx's socket times out (see
/// ``stallTimeout``).
///
/// acpx holds its limits for each session's owner, and leaves uncounted what its socket's own
/// buffer holds: one 64 KiB piece of the frame going out. Its spool is a temp file; acpxd holds
/// the output in memory, so its limits hold for all sessions together, and the frame going out
/// counts in full, as the transport holds all of it.
final class CallerOutbox: @unchecked Sendable {
    /// The outbox of the call being served (``ACPXDaemonBackend/servingCall(isolation:_:)``).
    @TaskLocal static var current: CallerOutbox?

    /// acpx's `QueueOutputLimits`, and the budget they are counted against.
    struct Limits: Sendable {
        /// What one call's client may have unsent (`observerBytes`).
        var callBytes = 64 << 20
        /// What all of them may have unsent (`totalBytes`).
        var totalBytes = 256 << 20
        /// How many calls may have output unsent (`observers`).
        var calls = 64
        /// Shared by every call whose outbox these limits made.
        var budget = Budget()

        /// The limits acpxd runs with.
        static let daemon = Limits()
    }

    /// The limits a new outbox is made with: the daemon's, or a test's.
    @TaskLocal static var limits = Limits.daemon

    /// How long a client may leave its output unread before its transport disconnects it, in
    /// seconds — acpx's `DRAIN_TIMEOUT_MS`, which is one second. acpx's owner writes to a Unix
    /// socket of 8 KB buffers, where every read of a slow observer shows as progress. acpxd's
    /// CLIs are on loopback TCP, where the stack takes a slow reader's data in bursts up to
    /// about 5 s apart (its zero-window probes; see `sendStallTimeout`). One second would cut
    /// off a CLI still reading at tens of KB a second, which acpx keeps. Ten seconds keeps it,
    /// and still disconnects one that stopped.
    static let stallTimeout: TimeInterval = 10

    private let session: Session
    private let limits: Limits
    private let lock = NSLock()
    /// What waits while an earlier message goes out: its frame, its level, and what it counts.
    /// Posted onto `incoming`, and taken from the end of `outgoing` — `incoming` reversed, once
    /// `outgoing` runs out — so that what is taken is let go of at once: what the outbox holds
    /// is what it counts.
    private var incoming: [Waiting] = []
    private var outgoing: [Waiting] = []
    /// What the client has yet to be sent: what waits, and the message going out.
    private var unsentBytes = 0
    /// What the message going out counts: given back once it has gone.
    private var sendingBytes = 0
    /// Whether a message is going out, or is about to — the next waits — and the call counted
    /// among those with output unsent.
    private var sending = false
    /// Past a bound: the client is disconnected, and nothing more goes out.
    private var dropped = false
    private var idle: [CheckedContinuation<Void, Never>] = []
    /// The disconnect past a bound, which the call's end waits for (``flush()``).
    private var disconnection: Task<Void, Never>?

    init(session: Session, limits: Limits = CallerOutbox.limits) {
        self.session = session
        self.limits = limits
    }

    /// Send `message` after those before it: at once when none goes out, else once they
    /// have — as acpx writes to the socket what it takes, and spools the rest. Waits only to
    /// read the client's log level: below it, the message would never go out, so it takes no
    /// room either, as ``Session/sendLogNotification(_:)`` never sends it.
    func post(_ message: LogMessage) async {
        guard message.level.isAtLeast(await session.minimumLogLevel), let frame = Self.frame(of: message) else {
            return
        }
        let startsSending: Bool = lock.withLock {
            guard !dropped else { return false }
            // Counted as it is posted, the one that goes out at once too, as acpx reserves
            // before it writes; and until it has gone, as the transport holds it until then.
            let bytes = frame.count
            guard unsentBytes + bytes <= limits.callBytes,
                  limits.budget.reserve(bytes, newCall: !sending, limits: limits) else {
                dropAll()
                let session = session
                disconnection = Task { await session.disconnect() }
                return false
            }
            unsentBytes += bytes
            incoming.append(Waiting(frame: frame, level: message.level, bytes: bytes))
            let starts = !sending
            sending = true
            return starts
        }
        // The outbox's own task: what it sends outlives the post, and the call's end waits for
        // it (``flush()``).
        if startsSending { Task { await self.drain() } }
    }

    /// Whether a bound was passed, the client disconnected: nothing more goes out.
    var isDropped: Bool {
        lock.withLock { dropped }
    }

    /// How many messages wait, the one going out not among them: for a test.
    var waitingCount: Int {
        lock.withLock { incoming.count + outgoing.count }
    }

    /// Once the outbox holds nothing: all that was posted gone out — or, the client disconnected
    /// past a bound, the message going out let go of, and the disconnect done, so that the
    /// call's result does not reach the client first, as a success that lost part of its output.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                guard sending else { return true }
                idle.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
        await lock.withLock({ disconnection })?.value
    }

    /// Send what is posted, in order, until nothing waits — as the client's session, which a
    /// transport sends by (``Session/current``), whatever posted — and as
    /// ``Session/sendLogNotification(_:)`` sends: nothing below the client's log level, and a
    /// failed send let go.
    private func drain() async {
        await session.work { session in
            while let (frame, level) = self.next() {
                guard level.isAtLeast(await session.minimumLogLevel) else { continue }
                try? await session.transport?.send(frame)
            }
        }
    }

    /// The next frame to send, and its level, no longer waiting — the one sent before it gone,
    /// and no longer counted — or none, the outbox idle, and the call no longer counted among
    /// those with output unsent.
    private func next() -> (Data, LogLevel)? {
        let (message, woken): ((Data, LogLevel)?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            unsentBytes -= sendingBytes
            limits.budget.release(sendingBytes, call: false)
            sendingBytes = 0
            if outgoing.isEmpty, !dropped {
                outgoing = incoming.reversed()
                incoming = []
            }
            guard !dropped, let next = outgoing.popLast() else {
                sending = false
                limits.budget.release(0, call: true)
                (incoming, outgoing) = ([], [])
                return (nil, takeIdle())
            }
            sendingBytes = next.bytes
            return ((next.frame, next.level), [])
        }
        woken.forEach { $0.resume() }
        return message
    }

    /// Past a bound: what waits dropped, its budget given back. The message going out still
    /// counts, and keeps the call counted, until its send ends (``next()``), as acpx keeps an
    /// observer's slot until its socket closes. Under ``lock``.
    private func dropAll() {
        dropped = true
        limits.budget.release(unsentBytes - sendingBytes, call: false)
        unsentBytes = sendingBytes
        (incoming, outgoing) = ([], [])
    }

    /// Those waiting for the outbox to go idle. Under ``lock``.
    private func takeIdle() -> [CheckedContinuation<Void, Never>] {
        defer { idle = [] }
        return idle
    }

    /// The frame `message` goes out as: the `notifications/message` notification
    /// ``Session/sendLogNotification(_:)`` sends, encoded as a transport encodes it.
    static func frame(of message: LogMessage) -> Data? {
        var params: JSONDictionary = ["level": .string(message.level.rawValue), "data": message.data]
        if let logger = message.logger { params["logger"] = .string(logger) }
        return try? JSONRPCMessage.notification(method: "notifications/message", params: .object(params)).encoded()
    }

    /// What `message` counts: its frame.
    static func size(of message: LogMessage) -> Int {
        frame(of: message)?.count ?? 0
    }
}

extension CallerOutbox {
    /// A message waiting: the frame it goes out as, its level, and what it counts.
    struct Waiting {
        let frame: Data
        let level: LogLevel
        let bytes: Int
    }

    /// What all calls have waiting, and how many have some (acpx's `QueueOutputBudget`).
    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var calls = 0

        /// Room for `more` bytes of a call's waiting output — the call counted among those
        /// with some, if it was not yet.
        func reserve(_ more: Int, newCall: Bool, limits: Limits) -> Bool {
            lock.withLock {
                guard !newCall || calls < limits.calls, more <= limits.totalBytes - bytes else { return false }
                bytes += more
                if newCall { calls += 1 }
                return true
            }
        }

        func release(_ fewer: Int, call: Bool) {
            lock.withLock {
                bytes -= fewer
                if call { calls -= 1 }
            }
        }

        /// What is unsent, and for how many calls: for a test.
        var held: (bytes: Int, calls: Int) {
            lock.withLock { (bytes, calls) }
        }
    }
}
