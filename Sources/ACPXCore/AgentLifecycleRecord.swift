import Foundation
import SwiftACP

extension SessionRecord {
    /// acpx's `applyLifecycleSnapshotToRecord`: the agent's pid while it runs, when it
    /// was started, and how it last ended — or no end at all, when it has not.
    /// Nothing changes without a snapshot (an agent that cannot be watched).
    public mutating func applyLifecycle(_ snapshot: AgentLifecycleSnapshot?) {
        guard let snapshot else { return }
        pid = snapshot.running ? snapshot.pid.map(Int.init) : nil
        agentStartedAt = snapshot.startedAt
        guard let exit = snapshot.lastExit else {
            lastAgentExitCode = nil
            lastAgentExitSignal = nil
            lastAgentExitAt = nil
            lastAgentDisconnectReason = nil
            return
        }
        lastAgentExitCode = exit.exitCode.map { .value($0) } ?? .null
        lastAgentExitSignal = exit.signal.map { .value($0) } ?? .null
        lastAgentExitAt = exit.exitedAt
        lastAgentDisconnectReason = exit.reason.rawValue
    }
}
