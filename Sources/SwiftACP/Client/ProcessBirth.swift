#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// When a process started, read natively: the same pid with another birth is another
/// process. acpx tells its queue owner apart by the same (`processIdentity`,
/// `observeProcessIncarnation`, 0.19.2), where a pid alone lets a process that took over
/// the number pass for the owner.
public enum ProcessBirth {
    /// `pid`'s birth, to compare with another reading of it, or `nil` when it cannot be
    /// read: the process is gone or a zombie, or the table is out of reach. On Darwin
    /// it is the start time to the microsecond; on Linux, the start in clock ticks since
    /// boot, with the boot's id.
    public static func identity(of pid: pid_t) -> String? {
        #if canImport(Darwin)
        return started(pid).map { "darwin:\($0.tv_sec).\(String(format: "%06d", Int($0.tv_usec)))" }
        #else
        guard let ticks = linuxStart(pid), let boot = linuxBootId() else { return nil }
        return "linux:\(boot):\(ticks)"
        #endif
    }

    /// When `pid` started, by the wall clock, or `nil` when it cannot be read.
    public static func date(of pid: pid_t) -> Date? {
        #if canImport(Darwin)
        return started(pid).map { Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_usec) / 1_000_000) }
        #else
        guard let ticks = linuxStart(pid), let boot = linuxBootTime() else { return nil }
        let perSecond = Double(max(1, sysconf(Int32(_SC_CLK_TCK))))
        return Date(timeIntervalSince1970: boot + Double(ticks) / perSecond)
        #endif
    }

    #if canImport(Darwin)
    /// `kinfo_proc`'s start time for `pid`, unless it is gone or a zombie.
    private static func started(_ pid: pid_t) -> timeval? {
        guard pid > 0 else { return nil }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, u_int(name.count), &process, &length, nil, 0) == 0, length > 0,
            process.kp_proc.p_pid == pid, process.kp_proc.p_stat != SZOMB
        else { return nil }
        return process.kp_proc.p_un.__p_starttime
    }
    #else
    /// `/proc/<pid>/stat`'s start time, in clock ticks since boot.
    private static func linuxStart(_ pid: pid_t) -> UInt64? {
        guard pid > 0, let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else {
            return nil
        }
        return ProcessTable.parseStat(stat, pid: pid)?.birth
    }

    private static func linuxBootId() -> String? {
        (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `/proc/stat`'s `btime`: when the system booted, in seconds since 1970.
    private static func linuxBootTime() -> Double? {
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
        for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
            return Double(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
    #endif
}
#endif
