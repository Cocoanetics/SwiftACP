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

    /// Whether the daemon has been idle for the grace, as it is seen over time.
    struct Tracker {
        let grace: Duration
        private var since: ContinuousClock.Instant?

        init(grace: Duration) {
            self.grace = grace
        }

        /// Whether the daemon, found `idle` at `now`, has been idle for the grace since it was
        /// first found so: finding it busy starts the wait anew.
        mutating func observe(idle: Bool, at now: ContinuousClock.Instant) -> Bool {
            guard idle else {
                since = nil
                return false
            }
            let start = since ?? now
            since = start
            return now - start >= grace
        }
    }

    /// Look every `interval` whether the daemon is idle (`isIdle`), and once it has been for
    /// `grace`, stop it (`stop`), which says whether it did: one that found work meanwhile goes
    /// on, and is waited for anew.
    static func watch(
        grace: Duration = grace, interval: Duration = interval, isIdle: @escaping @Sendable () async -> Bool,
        stop: @escaping @Sendable () async -> Bool
    ) -> Task<Void, Never> {
        Task {
            var tracker = Tracker(grace: grace)
            while !Task.isCancelled {
                if tracker.observe(idle: await isIdle(), at: .now) {
                    if await stop() { return }
                    tracker = Tracker(grace: grace)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
