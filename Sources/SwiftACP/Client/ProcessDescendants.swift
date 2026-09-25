#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One live process, as the process table shows it.
struct ProcessTableEntry: Sendable, Equatable {
    let pid: pid_t
    let parentPid: pid_t
    let groupPid: pid_t
    /// When it started, in ``ProcessTable``'s units. A pid seen again with another
    /// birth is another process.
    let birth: UInt64
}

/// The system's process table, read natively where acpx runs `ps` (macOS) or reads
/// `/proc` (Linux). Zombies are left out: they cannot be signalled into exiting, and
/// their parent will reap them.
enum ProcessTable {
    /// Every live process, or `nil` when the table cannot be read.
    static func snapshot() -> [pid_t: ProcessTableEntry]? {
        #if canImport(Darwin)
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<4 {
            var length = 0
            guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0 else { return nil }
            let stride = MemoryLayout<kinfo_proc>.stride
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: length / stride + 32)
            length = processes.count * stride
            guard sysctl(&name, u_int(name.count), &processes, &length, nil, 0) == 0 else {
                if errno == ENOMEM { continue }  // the table grew in between
                return nil
            }
            var table: [pid_t: ProcessTableEntry] = [:]
            for process in processes.prefix(length / stride) where process.kp_proc.p_stat != SZOMB {
                let started = process.kp_proc.p_un.__p_starttime
                table[process.kp_proc.p_pid] = ProcessTableEntry(
                    pid: process.kp_proc.p_pid, parentPid: process.kp_eproc.e_ppid,
                    groupPid: process.kp_eproc.e_pgid,
                    birth: UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec))
            }
            return table
        }
        return nil
        #else
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        var table: [pid_t: ProcessTableEntry] = [:]
        for entry in entries {
            guard let pid = pid_t(entry), pid > 0,
                let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                let parsed = parseStat(stat, pid: pid)
            else { continue }
            table[pid] = parsed
        }
        return table
        #endif
    }

    #if !canImport(Darwin)
    /// `/proc/<pid>/stat`: after the parenthesised command name come the state, the
    /// parent, the process group, and — nineteen fields on — the start time in clock
    /// ticks since boot.
    static func parseStat(_ stat: String, pid: pid_t) -> ProcessTableEntry? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, fields[0] != "Z", fields[0] != "X",
            let parent = pid_t(fields[1]), let group = pid_t(fields[2]), let started = UInt64(fields[19])
        else { return nil }
        return ProcessTableEntry(pid: pid, parentPid: parent, groupPid: group, birth: started)
    }
    #endif

    /// The moment the root exited, to tell which group members it could have started
    /// (``ProcessDescendants``), or `nil` when the clock cannot be read.
    static func exitClock() -> ExitClock? {
        #if canImport(Darwin)
        var now = timeval()
        gettimeofday(&now, nil)
        return ExitClock(value: UInt64(now.tv_sec) * 1_000_000 + UInt64(now.tv_usec))
        #else
        // acpx's `readLinuxExitClock`: `/proc/uptime`, in centiseconds.
        guard let uptime = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8),
            let seconds = uptime.split(separator: " ").first
        else { return nil }
        let parts = seconds.split(separator: ".")
        guard let whole = UInt64(parts[0]) else { return nil }
        let hundredths = parts.count > 1 ? String((parts[1] + "00").prefix(2)) : "00"
        return ExitClock(value: whole * 100 + (UInt64(hundredths) ?? 0))
        #endif
    }

    struct ExitClock: Sendable {
        let value: UInt64

        /// Whether a process born at `birth` started no later than this moment.
        func isAfterBirth(_ birth: UInt64) -> Bool {
            #if canImport(Darwin)
            return birth <= value
            #else
            // Start ticks floor to USER_HZ and uptime to centiseconds: compare within
            // the exit's 10 ms interval, as acpx does.
            let ticksPerSecond = UInt64(max(1, sysconf(Int32(_SC_CLK_TCK))))
            return birth * 100 < (value + 1) * ticksPerSecond
            #endif
        }
    }
}

/// The processes a child started, tracked so they can be signalled with it — acpx's
/// `ProcessDescendants`. A terminal's command leads a process group of its own
/// (`ownProcessGroup`), whose members count as its; an agent shares this process's
/// group, so only what descends from it does.
///
/// Each ``capture(rootIsRunning:)`` reads the process table and keeps, by pid and
/// birth, every process seen before that is still the same process, with its own
/// group the members of the root's process group (while the root runs, or once more
/// after it exits for those it started before), and the children of anything kept. A
/// process that left the group — a daemon calling `setsid` — or lost its parent stays
/// tracked once it has been seen. The root itself is not among them: its owner
/// signals it.
final class ProcessDescendants {
    private let root: pid_t
    private let ownProcessGroup: Bool
    private var identities: [pid_t: ProcessTableEntry] = [:]
    private var rootBirth: UInt64?
    private var retired = false
    /// Whether the next snapshot still takes the root's group, although the root is
    /// gone: one fresh snapshot after the exit, for a shell's last fork.
    private var captureGroupAfterExit: Bool
    /// When the root exited: `.none` while it runs, `.some(nil)` if the clock could not
    /// be read (then no later group member counts).
    private var groupExitedAt: ProcessTable.ExitClock??

    init(root: pid_t, ownProcessGroup: Bool = true) {
        self.root = root
        self.ownProcessGroup = ownProcessGroup
        captureGroupAfterExit = ownProcessGroup
    }

    /// Record that the root has exited.
    func rootExited() {
        groupExitedAt = .some(ProcessTable.exitClock())
    }

    /// Refresh the tracked processes from a new snapshot. Returns `false` when the
    /// table could not be read.
    @discardableResult
    func capture(rootIsRunning: Bool) -> Bool {
        guard !retired else { return true }
        let captureRootGroup = ownProcessGroup && (rootIsRunning || captureGroupAfterExit)
        if !rootIsRunning { captureGroupAfterExit = false }
        guard var table = ProcessTable.snapshot() else { return false }
        // Custody never includes PID 1 or this process.
        table[1] = nil
        table[getpid()] = nil
        refresh(table, rootIsRunning: rootIsRunning, captureRootGroup: captureRootGroup)
        return true
    }

    private func refresh(_ table: [pid_t: ProcessTableEntry], rootIsRunning: Bool, captureRootGroup: Bool) {
        var owned = Set(identities.compactMap { pid, identity in
            table[pid]?.birth == identity.birth ? pid : nil
        })
        if rootIsRunning, let rootEntry = table[root] {
            rootBirth = rootBirth ?? rootEntry.birth
            if rootBirth == rootEntry.birth { owned.insert(root) }
        }
        // A shell can exit while a snapshot is in flight; later discovery needs a
        // witnessed member still in the group.
        if ownProcessGroup, captureRootGroup || owned.contains(where: { table[$0]?.groupPid == root }) {
            for entry in table.values where entry.groupPid == root && startedBeforeRootExit(entry) {
                owned.insert(entry.pid)
            }
        }
        var expanded = true
        while expanded {
            expanded = false
            for entry in table.values where owned.contains(entry.parentPid) && !owned.contains(entry.pid) {
                owned.insert(entry.pid)
                expanded = true
            }
        }
        owned.remove(root)
        identities = table.filter { owned.contains($0.key) }
    }

    private func startedBeforeRootExit(_ entry: ProcessTableEntry) -> Bool {
        guard let exited = groupExitedAt else { return true }
        guard let clock = exited else { return false }
        return clock.isAfterBirth(entry.birth)
    }

    /// Signal every process the snapshot just taken tracks: a saved pid is never
    /// signalled without its birth matching again, so a ``capture(rootIsRunning:)``
    /// that succeeded comes first. A signal refused is no sign the process is gone:
    /// only a fresh snapshot lets it go, as acpx 0.19.3 has it (#783).
    func signalTracked(_ signal: Int32) {
        guard !retired else { return }
        for pid in identities.keys { _ = kill(pid, signal) }
    }

    /// Whether any tracked process is still alive, as of the last snapshot.
    var hasTrackedProcesses: Bool { !identities.isEmpty }

    /// Stop tracking: the terminal is released.
    func retire() {
        retired = true
        identities.removeAll()
    }
}
#endif
