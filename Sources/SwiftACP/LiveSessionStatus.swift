import Foundation

/// Whether the daemon holds a session live — its agent connected and kept between
/// prompts, as acpx's queue owner keeps one — which the CLI's prompt banner and `status`
/// report (acpx's `probeQueueOwnerHealth`).
public struct LiveSessionStatus: Codable, Sendable, Equatable {
    /// Whether the daemon holds the session's agent live.
    public var live: Bool
    /// The agent's process id, while it runs.
    public var pid: Int?
    /// Whether the daemon holds it as acpx's queue owner holds one — a prompt's, until its TTL
    /// runs out — where acpx's CLI hands requests to the owner (#232). `nil` from a daemon that
    /// predates it.
    public var owned: Bool?

    public init(live: Bool, pid: Int? = nil, owned: Bool? = nil) {
        self.live = live
        self.pid = pid
        self.owned = owned
    }
}
