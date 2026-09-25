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
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func writeLock(_ holder: DaemonLock.Holder) throws {
        let url = ACPXPaths.daemonLockPath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(holder).write(to: url)
    }

    /// A birth reads the same each time, is the process's own, and is gone with it.
    @Test func aBirthIsAProcesssOwn() throws {
        let child = try sleeper()
        defer { stop(child) }
        let birth = try #require(ProcessBirth.identity(of: child.processIdentifier))
        #expect(ProcessBirth.identity(of: child.processIdentifier) == birth)
        #expect(ProcessBirth.identity(of: getpid()) != birth)
        let started = try #require(ProcessBirth.date(of: child.processIdentifier))
        #expect(abs(started.timeIntervalSinceNow) < 60)
        stop(child)
        #expect(ProcessBirth.identity(of: child.processIdentifier) == nil)
    }

    /// A lock naming a live pid whose process was born otherwise is stale: the CLI finds no
    /// daemon behind it, and a new daemon takes it, recording its own birth.
    @Test func aLockWhosePidAnotherProcessNowHoldsIsTakenOver() async throws {
        let child = try sleeper()
        defer { stop(child) }
        try await withIsolatedStore {
            let otherBirth = "darwin:1.000000"
            try writeLock(DaemonLock.Holder(pid: child.processIdentifier, startedAt: nowISO(), birth: otherBirth))
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
        let child = try sleeper()
        defer { stop(child) }
        try await withIsolatedStore {
            let birth = ProcessBirth.identity(of: child.processIdentifier)
            try writeLock(DaemonLock.Holder(pid: child.processIdentifier, startedAt: nowISO(), birth: birth))
            #expect(DaemonClient.liveHolder()?.pid == child.processIdentifier)
            #expect(try DaemonLock().acquire() == false)
            #expect(DaemonLock().currentHolder()?.pid == child.processIdentifier)
        }
    }

    /// A lock from before births were recorded is judged by when it was written: a process
    /// that started after that cannot have written it — as with #176's lock, naming
    /// launchd — while one that was running then may have.
    @Test func anOlderLockIsJudgedByWhenItWasWritten() async throws {
        let child = try sleeper()
        defer { stop(child) }
        try await withIsolatedStore {
            try writeLock(DaemonLock.Holder(pid: 1, startedAt: "2000-01-01T00:00:00.000Z"))
            #expect(try DaemonLock().acquire())
            DaemonLock().release()
            try writeLock(DaemonLock.Holder(pid: child.processIdentifier, startedAt: nowISO()))
            #expect(try DaemonLock().acquire() == false)
        }
    }
}
