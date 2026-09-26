@testable import ACPXCore
@testable import acpx
import Foundation
import SwiftACP
import Testing

/// A lock whose pid another process has taken since is stale (#176): the daemon tells its
/// holder by its birth, as acpx tells its queue owner (`observeProcessIncarnation`, 0.19.2),
/// so a crashed daemon's lock no longer keeps every new one out.
@Suite(.serialized) struct DaemonLockBirthTests {
    /// Some process that holds a pid now, standing in for one that took a crashed daemon's.
    private struct Sleeper {
        private let process = Process()
        private let exited: AsyncStream<Void>

        init() throws {
            let (exited, exit) = AsyncStream<Void>.makeStream()
            self.exited = exited
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.terminationHandler = { _ in exit.finish() }
            try process.run()
        }

        var pid: pid_t { process.processIdentifier }

        /// Stop it, and return once it has exited, as its termination handler says. Not with
        /// `waitUntilExit()`: that spins the calling thread's run loop until it notices the exit,
        /// and on a thread of the cooperative pool it did not, once in a full run (#186).
        func stop() async {
            if process.isRunning { process.terminate() }
            for await _ in exited {}
        }

        /// Stop it, not waiting for it to exit: the test's cleanup.
        func end() {
            if process.isRunning { process.terminate() }
        }
    }

    private func writeLock(_ holder: DaemonLock.Holder) throws {
        let url = ACPXPaths.daemonLockPath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(holder).write(to: url)
    }

    /// A birth reads the same each time, is the process's own, and is gone with it.
    @Test func aBirthIsAProcesssOwn() async throws {
        let child = try Sleeper()
        defer { child.end() }
        let birth = try #require(ProcessBirth.identity(of: child.pid))
        #expect(ProcessBirth.identity(of: child.pid) == birth)
        #expect(ProcessBirth.identity(of: getpid()) != birth)
        let started = try #require(ProcessBirth.date(of: child.pid))
        #expect(abs(started.timeIntervalSinceNow) < 60)
        await child.stop()
        #expect(ProcessBirth.identity(of: child.pid) == nil)
    }

    /// A lock naming a live pid whose process was born otherwise is stale: the CLI finds no
    /// daemon behind it, and a new daemon takes it, recording its own birth.
    @Test func aLockWhosePidAnotherProcessNowHoldsIsTakenOver() async throws {
        let child = try Sleeper()
        defer { child.end() }
        try await withIsolatedStore {
            let otherBirth = "darwin:1.000000"
            try writeLock(DaemonLock.Holder(pid: child.pid, startedAt: nowISO(), birth: otherBirth))
            #expect(DaemonClient.liveHolder() == nil)
            #expect(try DaemonLock().acquire())
            let taken = try #require(DaemonLock().currentHolder())
            #expect(taken.pid == getpid())
            #expect(taken.birth == ProcessBirth.identity(of: getpid()))
            DaemonLock().release()
        }
    }

    /// A lock whose holder is still the process that wrote it is not taken.
    @Test func aLockItsHolderStillHoldsIsNotTaken() async throws {
        let child = try Sleeper()
        defer { child.end() }
        try await withIsolatedStore {
            let birth = ProcessBirth.identity(of: child.pid)
            try writeLock(DaemonLock.Holder(pid: child.pid, startedAt: nowISO(), birth: birth))
            #expect(DaemonClient.liveHolder()?.pid == child.pid)
            #expect(try DaemonLock().acquire() == false)
            #expect(DaemonLock().currentHolder()?.pid == child.pid)
        }
    }

    /// A lock from before births were recorded is judged by when it was written: a process
    /// that started after that cannot have written it — as with #176's lock, naming
    /// launchd — while one that was running then may have.
    @Test func anOlderLockIsJudgedByWhenItWasWritten() async throws {
        let child = try Sleeper()
        defer { child.end() }
        try await withIsolatedStore {
            try writeLock(DaemonLock.Holder(pid: 1, startedAt: "2000-01-01T00:00:00.000Z"))
            #expect(try DaemonLock().acquire())
            DaemonLock().release()
            try writeLock(DaemonLock.Holder(pid: child.pid, startedAt: nowISO()))
            #expect(try DaemonLock().acquire() == false)
        }
    }
}
