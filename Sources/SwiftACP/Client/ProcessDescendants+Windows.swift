#if os(Windows)
import Foundation
import WinSDK

/// The processes an agent started, on Windows: those of its job (#272), where macOS and Linux look
/// them up in the process table. Ending them ends each but the agent itself, which
/// ``ChildProcess/send(_:)`` ends, as acpx signals an agent's descendants and then the agent.
final class ProcessDescendants: @unchecked Sendable {
    private let process: ChildProcess

    init(process: ChildProcess) {
        self.process = process
    }

    /// The job holds them all, so there is nothing to look for: always a look that worked.
    @discardableResult
    func capture(rootIsRunning: Bool) -> Bool {
        true
    }

    /// Each of the job's processes but the agent, ended: on Windows Node's `kill` terminates a
    /// process for any signal.
    func signalTracked(_ signal: Int32) {
        process.terminateDescendants()
    }

    /// Whether any of the job's processes but the agent still runs.
    var hasTrackedProcesses: Bool {
        let own = DWORD(bitPattern: process.pid)
        return process.jobProcessIds().contains { $0 != own }
    }

    /// Nothing to let go of: the job goes with the process.
    func retire() {}
}
#endif
