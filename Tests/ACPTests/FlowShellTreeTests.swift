@testable import ACPXFlows
import Foundation
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
        let exitNow: @Sendable () -> Void = {
            kill(pid, SIGKILL)
            // Once it is a zombie, which nothing reaps until the test ends.
            var info = siginfo_t()
            _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        }
        try await FlowShellTree.$beforeSignalling.withValue(exitNow) {
            try await FlowShellTree.stopPosixTree(pid, signal: SIGTERM)
        }
    }

    /// `arguments` started in a process group of its own, which it leads.
    private static func spawnInItsOwnGroup(_ arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], nil, &attributes, argv, nil)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }

    private static func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
#endif
