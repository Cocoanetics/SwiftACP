import Foundation

/// How long a turn waits, once the agent has answered, for the session's updates to go
/// quiet before it ends — acpx's queue owner waits so after every prompt (`runPromptTurn`'s
/// `waitForSessionUpdatesIdle`), so that updates the agent sends after its answer are
/// part of the turn. (`exec` and `compare` do not: `runOnce` ends at the answer.)
public struct ReplyDrain: Sendable, Equatable {
    /// How long the session's updates have to have been quiet.
    public var idleMilliseconds: Int
    /// How long to wait for that at most; past it, the turn ends all the same.
    public var timeoutMilliseconds: Int

    public init(idleMilliseconds: Int, timeoutMilliseconds: Int) {
        self.idleMilliseconds = idleMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    /// acpx's: a second of quiet (`SESSION_REPLY_IDLE_MS`), at most five
    /// (`SESSION_REPLY_DRAIN_TIMEOUT_MS`).
    public static let acpx = ReplyDrain(idleMilliseconds: 1_000, timeoutMilliseconds: 5_000)
}

/// The wait the daemon's turns use: acpx's (``ReplyDrain/acpx``), scoped to a task,
/// which lets tests shorten it.
public enum TurnReplyDrain {
    @TaskLocal public static var current = ReplyDrain.acpx
}
