@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

#if canImport(Darwin)
import Darwin

/// Stopping a shell command's process tree as acpx's `stopShellProcess` does.
struct FlowShellTreeTests {
    /// A group whose one member exits once the table is read, and before the group is
    /// signalled, is refused the signal, as a group of zombies is (EPERM). Stopping it is
    /// done, as acpx finds by reading `ps` again, not the failure the table read before the
    /// signal would make of it: `kill EPERM`, which failed a step at its deadline.
    @Test func aGroupThatExitsJustBeforeItsSignalIsStopped() async throws {
        let pid = try Self.spawnInItsOwnGroup(["/bin/sleep", "30"])
        defer { Self.reap(pid) }
        let exitNow: @Sendable () -> Void = { Self.endUnreaped(pid) }
        try await FlowShellTree.$beforeSignalling.withValue(exitNow) {
            try await FlowShellTree.stopPosixTree(pid, signal: SIGTERM)
        }
    }

    /// A group whose one member is exiting when it is signalled is refused the signal too:
    /// XNU has taken the member off its lookup, while the table lists it until its exit is
    /// done — under load, a second after its SIGTERM and more. Stopping it is done, not
    /// `kill EPERM`. A process cannot be held in its exit, so the member here is a zombie
    /// the table shows as it was a moment before: exiting.
    @Test func aGroupWhoseMemberIsExitingWhenSignalledIsStopped() async throws {
        let pid = try Self.spawnInItsOwnGroup(["/bin/sleep", "30"])
        defer { Self.reap(pid) }
        let state = Shared((entry: ProcessTableEntry?.none, refused: false, shown: false, reads: [String]()))
        let exitNow: @Sendable () -> Void = {
            Self.endUnreaped(pid)
            let refused = kill(-pid, 0) != 0 && errno == EPERM
            state.update { $0.refused = refused }
        }
        // The first read once it exited — the refused signal's — lists it as it was a moment before.
        let asRead: @Sendable (inout [pid_t: ProcessTableEntry]) -> Void = { table in
            state.update { seen in
                seen.reads.append(Self.describe(table[pid]))
                guard seen.refused else {
                    seen.entry = table[pid] ?? seen.entry
                    return
                }
                guard !seen.shown, let entry = seen.entry else { return }
                seen.shown = true
                table[pid] = ProcessTableEntry(
                    pid: pid, parentPid: entry.parentPid, groupPid: entry.groupPid, birth: entry.birth, exiting: true)
            }
        }
        try await FlowShellTree.$readingTable.withValue(asRead) {
            try await FlowShellTree.$beforeSignalling.withValue(exitNow) {
                try await FlowShellTree.stopPosixTree(pid, signal: SIGTERM)
            }
        }
        let (refused, shown, reads) = state.update { ($0.refused, $0.shown, $0.reads) }
        #expect(refused && shown, "reads: \(reads)")
    }

    /// A tree that exits as its SIGTERM grace ends — while a look at it runs past the
    /// grace, as a slow read or a late wake-up does on a loaded machine — is done, and not
    /// sent SIGKILL: only a look begun once the grace is over can find it still alive.
    @Test func aTreeGoneAsItsGraceEndsIsNotSignalledAgain() async throws {
        let pid = try Self.spawnInItsOwnGroup(["/bin/sleep", "30"], blocking: SIGTERM)
        defer { Self.reap(pid) }
        let state = Shared((signals: 0, slowed: false))
        let signalling: @Sendable () -> Void = { state.update { $0.signals += 1 } }
        // The first look runs past the grace, and the tree exits meanwhile.
        let slowLook: @Sendable () async -> Void = {
            let first: Bool = state.update { seen in
                defer { seen.slowed = true }
                return !seen.slowed
            }
            guard first else { return }
            Self.endUnreaped(pid)
            try? await Task.sleep(for: FlowShellTree.killGrace + .milliseconds(100))
        }
        try await FlowShellTree.$afterLooking.withValue(slowLook) {
            try await FlowShellTree.$beforeSignalling.withValue(signalling) {
                try await FlowShellTree.stopPosixTree(pid, signal: SIGTERM)
            }
        }
        #expect(state.update { $0.signals } == 1)
    }

    /// The same after SIGKILL: a tree still there at the first look after its SIGKILL — yet
    /// to act on it, as a process on a loaded machine can be for a second and more — and
    /// gone as the grace ends is stopped, not reported as "did not terminate after SIGKILL".
    @Test func aTreeGoneAsItsSIGKILLGraceEndsIsStopped() async throws {
        let pid = try Self.spawnInItsOwnGroup(["/bin/sleep", "30"], blocking: SIGTERM)
        defer { Self.reap(pid) }
        let state = Shared((signals: 0, entry: ProcessTableEntry?.none, looked: false, slowed: 0, reads: [String]()))
        let signalling: @Sendable () -> Void = { state.update { $0.signals += 1 } }
        // The first read after SIGKILL still lists it.
        let asRead: @Sendable (inout [pid_t: ProcessTableEntry]) -> Void = { table in
            state.update { seen in
                seen.reads.append("\(seen.signals): \(Self.describe(table[pid]))")
                guard seen.signals == 2 else {
                    seen.entry = table[pid] ?? seen.entry
                    return
                }
                guard !seen.looked else { return }
                seen.looked = true
                if table[pid] == nil { table[pid] = seen.entry }
            }
        }
        // The first look of each grace runs past it; after SIGKILL, the tree exits meanwhile.
        let slowLook: @Sendable () async -> Void = {
            let signals: Int? = state.update { seen in
                guard seen.slowed < seen.signals else { return nil }
                seen.slowed = seen.signals
                return seen.signals
            }
            guard let signals else { return }
            if signals == 2 { Self.waitForExit(pid) }
            try? await Task.sleep(for: FlowShellTree.killGrace + .milliseconds(100))
        }
        let stop: () async throws -> Void = {
            try await FlowShellTree.$readingTable.withValue(asRead) {
                try await FlowShellTree.$afterLooking.withValue(slowLook) {
                    try await FlowShellTree.$beforeSignalling.withValue(signalling) {
                        try await FlowShellTree.stopPosixTree(pid, signal: SIGTERM)
                    }
                }
            }
        }
        do {
            try await stop()
        } catch {
            Issue.record(error, "reads: \(state.update { $0.reads })")
        }
        let (signals, reads) = state.update { ($0.signals, $0.reads) }
        #expect(signals == 2, "reads: \(reads)")
    }

    /// `arguments` started in a process group of its own, which it leads — with `blocking`
    /// held off, so only another signal ends it.
    private static func spawnInItsOwnGroup(_ arguments: [String], blocking: Int32? = nil) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        if let blocking {
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, blocking)
            posix_spawnattr_setsigmask(&attributes, &mask)
            flags |= Int16(POSIX_SPAWN_SETSIGMASK)
        }
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], nil, &attributes, argv, nil)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }

    /// End `pid`, and wait until it is a zombie — which nothing reaps until the test ends.
    private static func endUnreaped(_ pid: pid_t) {
        kill(pid, SIGKILL)
        waitForExit(pid)
    }

    /// Wait until `pid` is a zombie, leaving it unreaped.
    private static func waitForExit(_ pid: pid_t) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
    }

    /// A process as a read of the table had it.
    private static func describe(_ entry: ProcessTableEntry?) -> String {
        guard let entry else { return "gone" }
        return "\(entry.pid) born \(entry.birth)\(entry.exiting ? " exiting" : "")"
    }

    private static func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

/// A value the stop's hooks and the test share.
private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
#endif
