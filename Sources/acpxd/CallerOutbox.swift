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
/// bounds count is what is held. What waits while one goes out is bounded as acpx bounds what
/// an observer's socket has not taken: 64 MiB for a call, 256 MiB for all calls, 64 calls with
/// output waiting. Past a bound, the client is disconnected (``Session/disconnect()``), as
/// acpx destroys that observer's socket, and nothing more goes to it; the turn goes on. A
/// client that leaves its output unread for ten seconds is disconnected by the transport
/// (`TCPBonjourTransport.sendStallTimeout`), as acpx's socket times out (see
/// ``stallTimeout``).
final class CallerOutbox: @unchecked Sendable {
    /// The outbox of the call being served (``ACPXDaemonBackend/servingCall(isolation:_:)``).
    @TaskLocal static var current: CallerOutbox?

    /// acpx's `QueueOutputLimits`, and the budget they are counted against.
    struct Limits: Sendable {
        /// What may wait for one call's client (`observerBytes`).
        var callBytes = 64 << 20
        /// What may wait for all of them (`totalBytes`).
        var totalBytes = 256 << 20
        /// How many calls may have output waiting (`observers`).
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
    /// What waits while an earlier message goes out: its frame, its level, and what it counts —
    /// from `head` on: those before it have gone, and are let go of in bulk, so taking the next
    /// costs no copy.
    private var waiting: [Waiting] = []
    private var head = 0
    private var waitingBytes = 0
    /// Whether a message is going out: the next waits.
    private var sending = false
    /// Past a bound: the client is disconnected, and nothing more goes out.
    private var dropped = false
    /// Counted among the calls with output waiting.
    private var holdsSlot = false
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
        enum Outcome { case waits, startsSending, overflows }
        guard message.level.isAtLeast(await session.minimumLogLevel), let frame = Self.frame(of: message) else {
            return
        }
        let outcome: Outcome = lock.withLock {
            guard !dropped else { return .waits }
            guard sending else {
                sending = true
                waiting.append(Waiting(frame: frame, level: message.level, bytes: 0))
                return .startsSending
            }
            let bytes = frame.count
            guard waitingBytes + bytes <= limits.callBytes,
                  limits.budget.reserve(bytes, newCall: !holdsSlot, limits: limits) else {
                dropAll()
                let session = session
                disconnection = Task { await session.disconnect() }
                return .overflows
            }
            holdsSlot = true
            waiting.append(Waiting(frame: frame, level: message.level, bytes: bytes))
            waitingBytes += bytes
            return .waits
        }
        switch outcome {
        case .waits, .overflows:
            break
        case .startsSending:
            // The outbox's own task: what it sends outlives the post, and the call's end waits
            // for it (``flush()``).
            Task { await self.drain() }
        }
    }

    /// Whether a bound was passed, the client disconnected: nothing more goes out.
    var isDropped: Bool {
        lock.withLock { dropped }
    }

    /// Once all that was posted has gone out — or the client was disconnected, and it never will:
    /// its disconnect done, so that the call's result does not reach it first, as a success
    /// that lost part of its output.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                guard sending, !dropped else { return true }
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

    /// The next frame to send, and its level, no longer waiting — or none, the outbox idle.
    private func next() -> (Data, LogLevel)? {
        let (message, woken): ((Data, LogLevel)?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard !dropped, head < waiting.count else {
                sending = false
                (waiting, head) = ([], 0)
                return (nil, takeIdle())
            }
            let next = waiting[head]
            head += 1
            if head >= 1024, head * 2 >= waiting.count {
                waiting.removeFirst(head)
                head = 0
            }
            waitingBytes -= next.bytes
            limits.budget.release(next.bytes, call: false)
            if head == waiting.count, holdsSlot {
                holdsSlot = false
                limits.budget.release(0, call: true)
            }
            return ((next.frame, next.level), [])
        }
        woken.forEach { $0.resume() }
        return message
    }

    /// Past a bound: what waits dropped, its budget given back. Under ``lock``.
    private func dropAll() {
        dropped = true
        limits.budget.release(waitingBytes, call: holdsSlot)
        (waiting, head, waitingBytes, holdsSlot) = ([], 0, 0, false)
        takeIdle().forEach { $0.resume() }
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
    /// A message waiting: the frame it goes out as, its level, and what it counts (nothing for
    /// the one sent at once).
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

        /// What waits, and for how many calls: for a test.
        var held: (bytes: Int, calls: Int) {
            lock.withLock { (bytes, calls) }
        }
    }
}
