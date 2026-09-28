import Foundation

/// The calls a daemon serves, and whether it takes more. A daemon started on demand stops taking
/// them as it stops for idleness (#253), and decides that in one step with taking them: no call
/// it took runs once it has given its lock up.
struct CallGate {
    enum State {
        /// It takes calls.
        case open
        /// It decides whether it stops: a call waits for the answer.
        case deciding
        /// It stopped: a call is refused.
        case closed
    }

    var inFlight = 0
    var state = State.open
    /// The calls waiting for the answer, told whether they are taken.
    var waiting: [CheckedContinuation<Bool, Never>] = []
    /// Told whenever a call waits for the answer — for a test.
    var onWait: (@Sendable () -> Void)?
}

/// A call a daemon that stopped for idleness does not take, refused as acpx's queue owner
/// refuses one once it shuts down (`enqueue`).
struct StoppedTakingCalls: LocalizedError {
    static let failure = ToolFailure(
        outputCode: "RUNTIME", detailCode: "QUEUE_OWNER_SHUTTING_DOWN", origin: "queue", retryable: true)

    var errorDescription: String? { "Queue owner is shutting down" }
}

extension ACPXDaemon {
    /// How many tool calls it is serving: each from its start until its work is over, however its
    /// client fares meanwhile (``serving(_:)``).
    public var callsInFlight: Int { calls.inFlight }

    /// Stop taking calls, if it serves none and `stop` — the backend's own look — says the daemon
    /// stops (#253). A call that comes meanwhile waits for the answer: it is served should the
    /// daemon go on, and refused once it stops. Returns whether it stopped.
    public func stopTakingCallsIfIdle(_ stop: @Sendable () async -> Bool) async -> Bool {
        guard calls.state == .open, calls.inFlight == 0 else { return false }
        calls.state = .deciding
        let stopped = await stop()
        calls.state = stopped ? .closed : .open
        let waiting = calls.waiting
        calls.waiting = []
        for call in waiting { call.resume(returning: !stopped) }
        return stopped
    }

    /// `work`, served (``serving(_:)``), its failure going to the caller with what it says beyond
    /// its message, as the backend describes it (``ACPXBackend/toolFailure(for:)``).
    func described<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await serving(work)
        } catch {
            let failure = error is StoppedTakingCalls ? StoppedTakingCalls.failure : backend.toolFailure(for: error)
            guard let failure, !failure.isEmpty else { throw error }
            throw DescribedToolFailure(underlying: error, failure: failure)
        }
    }

    /// `work`, once the daemon takes the call, one of the calls it serves (``callsInFlight``)
    /// until it is over.
    func serving<T>(_ work: () async throws -> T) async throws -> T {
        try await takeCall()
        calls.inFlight += 1
        defer { calls.inFlight -= 1 }
        return try await work()
    }

    /// Take a call, as the daemon takes calls now (``CallGate/State``).
    private func takeCall() async throws {
        switch calls.state {
        case .open:
            return
        case .closed:
            throw StoppedTakingCalls()
        case .deciding:
            let taken = await withCheckedContinuation { continuation in
                calls.waiting.append(continuation)
                calls.onWait?()
            }
            guard taken else { throw StoppedTakingCalls() }
        }
    }

    /// Be told whenever a call waits for the answer to whether the daemon stops — for a test.
    func observeWaits(_ observer: (@Sendable () -> Void)?) {
        calls.onWait = observer
    }
}
