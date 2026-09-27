import Foundation
import JSONFoundation
import SwiftACP

/// What acpx's ACP SDK makes of a `session/update` before acpx sees it, where SwiftACP
/// reads more: SwiftACP keeps a kind or a status the SDK doesn't know, and hands on some
/// updates the SDK refuses outright.
extension SessionUpdate {
    /// Whether the update reaches acpx at all. The SDK refuses a `usage_update` without
    /// numbers for `used` and `size` (``SwiftACP/UsageUpdate/reachesACPX``), and a
    /// `config_option_update` without `configOptions` (``ConfigOptionSchema``).
    public var reachesACPX: Bool {
        switch self {
        case .usageUpdate(let usage): return usage.reachesACPX
        case .other(kind: "config_option_update", let payload): return !ConfigOptionSchema.refuses(payload)
        default: return true
        }
    }
}

extension ToolKind {
    /// Whether acpx's ACP SDK knows the kind (`zToolKind`). It reads any other as none.
    var reachesACPX: Bool { Self.acpxKinds.contains(self) }

    private static let acpxKinds: Set<ToolKind> = [
        .read, .edit, .delete, .move, .search, .execute, .think, .fetch, "switch_mode", .other
    ]
}

extension ToolCallStatus {
    /// Whether acpx's ACP SDK knows the status (`zToolCallStatus`). It reads any other as
    /// none.
    var reachesACPX: Bool { Self.acpxStatuses.contains(self) }

    private static let acpxStatuses: Set<ToolCallStatus> = [.pending, .inProgress, .completed, .failed]
}
