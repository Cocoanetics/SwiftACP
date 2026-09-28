import Foundation
import SwiftACP

/// An agent a session's record still names by its `pid` as the session closes — left running,
/// held by no daemon — ended as acpx's `closeSession` ends it (#252): alive, and by its command
/// line the record's agent (`isLikelyMatchingProcess`), it is sent `SIGTERM`, and `SIGKILL`
/// when it outlives the grace (`terminateProcess`).
public enum StrayAgent {
    /// How long a signalled agent is given to end, in milliseconds: acpx's
    /// `PROCESS_SIGTERM_GRACE_MS` and `PROCESS_SIGKILL_GRACE_MS`.
    public struct Graces: Sendable {
        public var term: Int
        public var kill: Int

        public init(term: Int, kill: Int) {
            self.term = term
            self.kill = kill
        }
    }

    /// The graces an agent is given; a test shortens them.
    @TaskLocal public static var graces = Graces(term: 12_000, kill: 1_500)

    /// How often a signalled agent is looked at (`PROCESS_POLL_MS`).
    static let pollMilliseconds = 50

    /// How long `ps` may take to tell a command line (`PROCESS_HELPER_TIMEOUT_MS`).
    static let helperTimeoutMilliseconds = 8_000

    /// End the agent `record`'s pid names, when it still runs and its command line names the
    /// record's agent. Returns whether it ended.
    @discardableResult
    public static func end(namedBy record: SessionRecord) -> Bool {
        guard let pid = record.pid.flatMap({ Int32(exactly: $0) }), isAlive(pid), isLikelyAgent(pid, of: record)
        else { return false }
        return terminate(pid)
    }

    /// acpx's `isProcessAlive`: another process, there to be signalled — one that may not be
    /// (`EPERM`) counts as gone.
    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && pid != getpid() && kill(pid, 0) == 0
    }

    /// acpx's `isLikelyMatchingProcess`: one of the process's words — its executable among
    /// them — has the base name of the first of the record's agent command.
    static func isLikelyAgent(_ pid: Int32, of record: SessionRecord) -> Bool {
        guard let expected = firstCommandToken(of: record) else { return false }
        let wanted = Array(NodePath.basename(expected).utf8)
        return argv(of: pid).contains { Array(NodePath.basename($0).utf8) == wanted }
    }

    /// acpx's `firstAgentCommandToken`: the first of the record's argv, or else of its command
    /// line split as acpx splits one — none when that is empty or cannot be split.
    static func firstCommandToken(of record: SessionRecord) -> String? {
        if let argv = record.agentArgv { return argv.first.flatMap { $0.isEmpty ? nil : $0 } }
        return (try? AgentRegistry.commandLineParts(record.agentCommand))?.first
    }

    /// acpx's `readProcessArgv` where there is no `/proc`: the process's command line as `ps`
    /// tells it, split as a command line — or, one that can't be, at its whitespace.
    static func argv(of pid: Int32) -> [String] {
        guard let line = commandLine(of: pid) else { return [] }
        if let parts = try? AgentRegistry.commandLineParts(line) { return parts }
        return Array(line.utf16).split(whereSeparator: SessionRecordParser.isJavaScriptWhitespace)
            .map { String(decoding: $0, as: UTF16.self) }
    }

    /// `ps -p <pid> -o command=` as acpx runs it (`runTimedExecFile`): what it wrote, trimmed —
    /// `nil` when that is nothing, or `ps` fails or is killed for running past its time.
    static func commandLine(of pid: Int32) -> String? {
        guard let ps = AgentRegistry.which("ps") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ps)
        process.arguments = ["-p", String(pid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let overdue = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(helperTimeoutMilliseconds), execute: overdue)
        let written = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        overdue.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        let trimmed = SessionRecordParser.javaScriptTrimmed(Array(String(decoding: written, as: UTF8.self).utf16))
        return trimmed.isEmpty ? nil : String(decoding: trimmed, as: UTF16.self)
    }

    /// acpx's `terminateProcess`: `SIGTERM`, then `SIGKILL` once its grace is past, each
    /// followed by a look every 50 ms until the process is gone or the grace runs out.
    /// Returns whether it ended; a signal that can't be sent ends the try.
    static func terminate(_ pid: Int32) -> Bool {
        guard isAlive(pid) else { return false }
        let graces = graces
        for (signal, grace) in [(SIGTERM, graces.term), (SIGKILL, graces.kill)] {
            guard kill(pid, signal) == 0 else { return false }
            if waitForExit(pid, within: grace) { return true }
        }
        return false
    }

    /// acpx's `waitForProcessExit`: whether the process is gone within `milliseconds`.
    private static func waitForExit(_ pid: Int32, within milliseconds: Int) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(max(0, milliseconds))
        while DispatchTime.now() <= deadline {
            if !isAlive(pid) { return true }
            usleep(useconds_t(pollMilliseconds * 1_000))
        }
        return !isAlive(pid)
    }
}
