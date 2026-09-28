import Foundation

/// What `cancelSession` did: whether a turn was cancelled, and — when the session's owner took
/// the cancel, as acpx's queue owner takes one while it holds the session — the pid of the daemon
/// it runs in, which acpx's CLI names under `--verbose` (#232).
public struct SessionCancelResult: Codable, Sendable, Equatable {
    /// Whether the session ran a turn, which was cancelled.
    public var cancelled: Bool
    /// The pid of the daemon whose owner of the session took the cancel; `nil` when none held
    /// it, and from a daemon that predates it.
    public var ownerPid: Int?

    public init(cancelled: Bool, ownerPid: Int? = nil) {
        self.cancelled = cancelled
        self.ownerPid = ownerPid
    }

    private enum CodingKeys: String, CodingKey {
        case cancelled, ownerPid
    }

    /// Also reads what a daemon from before this result returned: whether it cancelled, alone.
    /// The daemon outlives the CLI, so one upgraded while such a daemon still runs keeps
    /// working with it.
    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            cancelled = try keyed.decode(Bool.self, forKey: .cancelled)
            ownerPid = try keyed.decodeIfPresent(Int.self, forKey: .ownerPid)
            return
        }
        cancelled = try decoder.singleValueContainer().decode(Bool.self)
        ownerPid = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cancelled, forKey: .cancelled)
        try container.encodeIfPresent(ownerPid, forKey: .ownerPid)
    }
}
