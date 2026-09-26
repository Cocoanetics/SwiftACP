import Foundation
import SwiftACP

#if canImport(Darwin)
import Darwin
#endif

/// acpx's `src/flows/executors/shell-process.ts` (v0.19.3): stopping a shell command with
/// everything it started — its process group, and the descendants that left it — then
/// waiting for its pipes to close. acpx reads the process table with `ps`; this reads it
/// natively (``ProcessTable``), and keeps each process by pid and birth, so a pid used
/// again is never signalled.
enum FlowShellTree {
    /// acpx's `KILL_GRACE_MS`: how long each signal is given, and the pipes after them.
    static let killGrace: Duration = .seconds(1)

    /// acpx's `stopShellProcess`: the tree stopped with `signal`, then SIGKILL; then the
    /// pipes closed. A failure to stop is reported once the pipes have closed.
    static func stop(_ root: pid_t, signal: Int32, closed: FlowShellEvent) async throws {
        do {
            try await stopPosixTree(root, signal: signal)
        } catch {
            do {
                try await waitForClose(closed)
            } catch let closeError {
                throw FlowShellCleanupError("Shell process cleanup failed", errors: [error, closeError])
            }
            throw error
        }
        try await waitForClose(closed)
    }

    /// acpx's `stopPosixTree`.
    static func stopPosixTree(_ root: pid_t, signal: Int32) async throws {
        var owned = Owned(root: root)
        do {
            try signalOwned(&owned, signal)
            if try await waitForOwned(&owned) { return }
            try signalOwned(&owned, SIGKILL)
            if try await !waitForOwned(&owned) {
                throw FlowShellError("Shell process tree did not terminate after SIGKILL")
            }
        } catch {
            do {
                try forceKnownProcesses(owned)
            } catch let cleanupError {
                throw FlowShellCleanupError("Shell process cleanup failed", errors: [error, cleanupError])
            }
            throw error
        }
    }

    /// acpx's `hasShellProcesses`: whether anything is left in the command's process group.
    static func hasProcesses(_ root: pid_t) -> Bool {
        kill(-root, 0) == 0 || errno != ESRCH
    }

    // MARK: - The tree

    /// The processes the command owns: acpx's `owned` set, by pid and birth.
    struct Owned {
        let root: pid_t
        private(set) var births: [pid_t: UInt64] = [:]

        init(root: pid_t) {
            self.root = root
        }

        /// acpx's `rememberOwnedProcesses`: every member of the root's group, and every
        /// descendant of what is owned — the root included, until it is gone.
        mutating func remember(_ table: [pid_t: ProcessTableEntry]) {
            var owned = Set(births.compactMap { pid, birth in table[pid]?.birth == birth ? pid : nil })
            if let rootEntry = table[root], births[root] == nil || births[root] == rootEntry.birth {
                owned.insert(root)
            }
            for entry in table.values where entry.groupPid == root { owned.insert(entry.pid) }
            var grew = true
            while grew {
                grew = false
                for entry in table.values where owned.contains(entry.parentPid) && !owned.contains(entry.pid) {
                    owned.insert(entry.pid)
                    grew = true
                }
            }
            for pid in owned { births[pid] = table[pid]?.birth ?? births[pid] }
        }

        /// Whether any owned process is alive in `table` — the same process, by its birth.
        func anyAlive(in table: [pid_t: ProcessTableEntry]) -> Bool {
            births.contains { pid, birth in table[pid]?.birth == birth }
        }
    }

    private static func snapshot() throws -> [pid_t: ProcessTableEntry] {
        guard let table = ProcessTable.snapshot() else { throw FlowShellError("The process table could not be read") }
        return table
    }

    /// acpx's `signalOwned`: the group signalled once, and each owned process outside it
    /// on its own.
    private static func signalOwned(_ owned: inout Owned, _ signal: Int32) throws {
        let table = try snapshot()
        owned.remember(table)
        try signalGroup(owned.root, signal, table: table)
        for (pid, birth) in owned.births where table[pid]?.birth == birth && table[pid]?.groupPid != owned.root {
            try signalProcess(pid, signal)
        }
    }

    /// acpx's `waitForOwned`: until nothing owned is alive, looking every 25 ms, for the
    /// grace period.
    private static func waitForOwned(_ owned: inout Owned) async throws -> Bool {
        let deadline = ContinuousClock.now + killGrace
        repeat {
            let table = try snapshot()
            owned.remember(table)
            if !owned.anyAlive(in: table) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return false
    }

    /// acpx's `forceKnownProcesses`: SIGKILL to the group and every process known.
    private static func forceKnownProcesses(_ owned: Owned) throws {
        let table = ProcessTable.snapshot() ?? [:]
        var errors: [Error] = []
        do { try signalGroup(owned.root, SIGKILL, table: table) } catch { errors.append(error) }
        for (pid, birth) in owned.births where table[pid]?.birth == birth {
            do { try signalProcess(pid, SIGKILL) } catch { errors.append(error) }
        }
        if !errors.isEmpty { throw FlowShellCleanupError("Known shell processes could not be stopped", errors: errors) }
    }

    /// acpx's `signalGroup`: gone is done; not allowed is done too when none of the group
    /// is alive.
    private static func signalGroup(_ root: pid_t, _ signal: Int32, table: [pid_t: ProcessTableEntry]) throws {
        guard kill(-root, signal) != 0 else { return }
        let failure = errno
        if failure == ESRCH { return }
        if failure == EPERM, !table.values.contains(where: { $0.groupPid == root }) { return }
        throw FlowShellKillError(code: failure)
    }

    /// acpx's `signalPid`: gone is done.
    private static func signalProcess(_ pid: pid_t, _ signal: Int32) throws {
        guard kill(pid, signal) != 0 else { return }
        let failure = errno
        if failure == ESRCH { return }
        throw FlowShellKillError(code: failure)
    }

    /// acpx's `waitForShellClose`: the pipes closed within the grace period.
    private static func waitForClose(_ closed: FlowShellEvent) async throws {
        guard await closed.wait(for: killGrace) else {
            throw FlowShellError("Shell process streams did not close after termination")
        }
    }
}

/// acpx's `AggregateError`s for a shell's cleanup: the message, and what failed.
struct FlowShellCleanupError: Error, LocalizedError {
    let message: String
    let errors: [Error]
    init(_ message: String, errors: [Error]) {
        self.message = message
        self.errors = errors
    }
    var errorDescription: String? { message }
}

/// A signal `kill` refused, as Node's `process.kill` reports it: `kill EPERM`.
struct FlowShellKillError: Error, LocalizedError {
    let code: Int32
    var errorDescription: String? { "kill \(ChildSpawn.SpawnError(code: code).name)" }
}

/// A one-off event several can wait for — a shell's pipes closing — with a bound.
final class FlowShellEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var happened = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func fire() {
        let waiting: [CheckedContinuation<Bool, Never>] = lock.withLock {
            guard !happened else { return [] }
            happened = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in waiting { waiter.resume(returning: true) }
    }

    var hasHappened: Bool { lock.withLock { happened } }

    /// Whether it happens within `timeout`.
    func wait(for timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let already: Bool = lock.withLock {
                if happened { return true }
                waiters[id] = continuation
                return false
            }
            if already {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let waiting = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                waiting?.resume(returning: false)
            }
        }
    }
}
