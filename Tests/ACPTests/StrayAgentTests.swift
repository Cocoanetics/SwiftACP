@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A close ends the agent its record still names by its `pid` — left running, held by no daemon —
/// as acpx's `closeSession` does (#252): alive and, by its command line, the record's agent, it is
/// sent `SIGTERM`, then `SIGKILL` past the grace. Whatever else the pid names is left alone.
@Suite(.serialized) struct StrayAgentTests {
    /// `/bin/sleep 30` under the name `argv0` — `SIGTERM` held off when `stubborn` — reaped as it
    /// ends, so that it is gone, not a zombie, once it has. Its pid. Its signal mask is its own:
    /// the pool thread spawning it blocks signals, which it would otherwise keep.
    static func sleeper(as argv0: String = "/bin/sleep", stubborn: Bool = false) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        sigemptyset(&mask)
        if stubborn { sigaddset(&mask, SIGTERM) }
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
        }
        // Typed apart: Swift 6.3 reads a literal mapped by `strdup` as its pointers.
        let words: [String] = [argv0, "30"]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sleep", &actions, &attributes, argv, nil)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return pid
    }

    /// A sleeper a test is done with, gone.
    static func stop(_ pid: pid_t) {
        if StrayAgent.isAlive(pid) { kill(pid, SIGKILL) }
    }

    /// A session of `agentCommand`'s in `cwd` whose record names `pid`.
    static func record(_ id: String, agentCommand: String, cwd: String = "/tmp", pid: pid_t) -> SessionRecord {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: agentCommand, cwd: cwd, createdAt: now, lastUsedAt: now)
        record.pid = Int(pid)
        return record
    }

    /// With no daemon running, `sessions close` ends the agent its record names, and marks the
    /// record closed, its pid gone.
    @Test(.timeLimit(.minutes(1)))
    func aCloseEndsTheAgentItsRecordStillNames() async throws {
        let pid = try Self.sleeper()
        defer { Self.stop(pid) }
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            try SessionStore.writeRecord(
                Self.record("stray", agentCommand: "/bin/sleep 30", cwd: directory.path, pid: pid))
            let run = await CLIParityTests.run(
                ["--agent", "/bin/sleep 30", "--cwd", directory.path, "sessions", "close"])
            #expect(run.code == ExitCodes.success, "\(run.err)")
            #expect(!StrayAgent.isAlive(pid))
            let record = try #require(SessionStore.loadRecord("stray"))
            #expect(record.closed == true)
            #expect(record.pid == nil)
        }
    }

    /// A daemon that closes the record, not holding the agent it names, leaves that agent to
    /// the close all the same, as acpx ends it once its owner has closed the session.
    @Test(.timeLimit(.minutes(1)))
    func aCloseThroughTheDaemonEndsTheAgentToo() async throws {
        let pid = try Self.sleeper()
        defer { Self.stop(pid) }
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            try SessionStore.writeRecord(
                Self.record("stray", agentCommand: "/bin/sleep 30", cwd: directory.path, pid: pid))
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let (code, err) = await ReconnectFallbackLineTests.acpx(
                ["sessions", "close"], agent: "/bin/sleep 30", cwd: directory, backend: backend)
            #expect(code == ExitCodes.success, "\(err)")
            #expect(!StrayAgent.isAlive(pid))
            #expect(try #require(SessionStore.loadRecord("stray")).closed == true)
            await backend.releaseAll()
        }
    }

    /// A pid whose command line is not the agent's — none of its words has the base name of the
    /// agent command's first — is left running; the record is closed all the same.
    @Test(.timeLimit(.minutes(1)))
    func aProcessThatIsNotTheAgentIsLeftAlone() async throws {
        let pid = try Self.sleeper()
        defer { Self.stop(pid) }
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let agent = "/opt/agents/codex-acp --acp"
            try SessionStore.writeRecord(Self.record("other", agentCommand: agent, cwd: directory.path, pid: pid))
            let run = await CLIParityTests.run(["--agent", agent, "--cwd", directory.path, "sessions", "close"])
            #expect(run.code == ExitCodes.success, "\(run.err)")
            #expect(StrayAgent.isAlive(pid))
            #expect(try #require(SessionStore.loadRecord("other")).closed == true)
        }
    }

    /// One that holds off `SIGTERM` is sent `SIGKILL` once its grace is past (`terminateProcess`).
    @Test(.timeLimit(.minutes(1)))
    func anAgentThatOutlastsTheGraceIsKilled() throws {
        let pid = try Self.sleeper(stubborn: true)
        defer { Self.stop(pid) }
        let record = Self.record("stubborn", agentCommand: "/bin/sleep 30", pid: pid)
        let started = DispatchTime.now()
        let ended = StrayAgent.$graces.withValue(StrayAgent.Graces(term: 300, kill: 1_500)) {
            StrayAgent.end(namedBy: record)
        }
        #expect(ended)
        #expect(!StrayAgent.isAlive(pid))
        // `SIGTERM` alone could not end it: it went only once the grace was past.
        #expect(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds >= 300_000_000)
    }

    /// The process's words are what `ps` says of it, split as a command line — or at its
    /// whitespace, when they can't be (an unmatched quote) — and a record's argv names its agent
    /// before its command line does.
    @Test(.timeLimit(.minutes(1)))
    func theCommandLineIsReadAsAcpxReadsIt() throws {
        let pid = try Self.sleeper(as: "it's-an-agent")
        defer { Self.stop(pid) }
        #expect(StrayAgent.argv(of: pid) == ["it's-an-agent", "30"])
        var record = Self.record("named", agentCommand: "/bin/sleep 30", pid: pid)
        #expect(!StrayAgent.isLikelyAgent(pid, of: record))
        record.agentArgv = ["/usr/local/bin/it's-an-agent", "--acp"]
        #expect(StrayAgent.isLikelyAgent(pid, of: record))
    }

    /// The agent's first word is acpx's `firstAgentCommandToken`: the first of its argv, else of
    /// its command line as acpx splits one — none when that can't be split.
    @Test func theAgentsFirstWordIsAcpxs() {
        var record = Self.record("words", agentCommand: "'/opt/my agent/run' --acp", pid: 1)
        #expect(StrayAgent.firstCommandToken(of: record) == "/opt/my agent/run")
        record.agentArgv = ["/bin/codex-acp", "--x"]
        #expect(StrayAgent.firstCommandToken(of: record) == "/bin/codex-acp")
        record.agentArgv = nil
        record.agentCommand = "'unterminated --acp"
        #expect(StrayAgent.firstCommandToken(of: record) == nil)
    }
}
