import Foundation

/// When an acpxd that acpx started on demand stops by itself (#253): once it has held no session
/// and served no call for ``grace``. acpx starts a queue owner for a session, and the owner exits
/// once its TTL passes with no task (`runQueueOwnerRuntime`). acpxd holds each session as such
/// an owner would, and lets it go at its TTL: once it holds none, nothing is left that acpx would
/// keep running. The grace bridges the steps of one command, and commands run one after another.
///
/// A daemon started any other way — by its user, by launchd, or hosted by an app — runs until it
/// is stopped.
enum IdleExit {
    /// How long a daemon started on demand waits, holding nothing and serving nothing, before it
    /// stops — longer than acpx waits for the daemon it started to be reachable, so the daemon
    /// is there for that command's first call.
    static let grace: Duration = .seconds(10)
    /// How often it looks.
    static let interval: Duration = .milliseconds(500)

    /// What a look at the daemon finds: whether it is idle — no call in flight, no session held —
    /// and how many calls it has taken so far, which tells a call taken and over since the last
    /// look, however fast (Codex review on #289).
    struct Look: Sendable, Equatable {
        var idle: Bool
        var callsTaken: Int
    }

    /// Whether the daemon has been idle for the grace, as it is seen over time.
    struct Tracker {
        let grace: Duration
        private var since: ContinuousClock.Instant?
        private var callsTaken: Int?

        init(grace: Duration) {
            self.grace = grace
        }

        /// Whether the daemon, as `look` finds it at `now`, has been idle for the grace since it
        /// was first found so: finding it busy — or having taken a call since the last look —
        /// starts the wait anew.
        mutating func observe(_ look: Look, at now: ContinuousClock.Instant) -> Bool {
            defer { callsTaken = look.callsTaken }
            guard look.idle, look.callsTaken == callsTaken ?? look.callsTaken else {
                since = nil
                return false
            }
            let start = since ?? now
            since = start
            return now - start >= grace
        }
    }

    /// Look at the daemon every `interval` (`look`), and once it has been idle for `grace`, stop
    /// it (`stop`) — unless it has taken a call since that look, whose count `stop` is given. It
    /// says whether it stopped: one that found work meanwhile goes on, and is waited for anew.
    static func watch(
        grace: Duration = grace, interval: Duration = interval, look: @escaping @Sendable () async -> Look,
        stop: @escaping @Sendable (_ callsTaken: Int) async -> Bool
    ) -> Task<Void, Never> {
        Task {
            var tracker = Tracker(grace: grace)
            while !Task.isCancelled {
                let seen = await look()
                if tracker.observe(seen, at: .now) {
                    if await stop(seen.callsTaken) { return }
                    tracker = Tracker(grace: grace)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
