@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// acpx 0.19.3's session ownership (`turn-ownership.ts`), file for file (#175: #781, #784): the
/// marker and fs-safe's guard beside it, as acpx writes them and judges them — held while
/// their owner lives, taken back once it is gone — and the import and `sessions ensure` that
/// take them.
@Suite(.serialized) struct SessionOwnershipTests {
    /// The marker is acpx's owner and when it was taken; the guard, the owner and a token of
    /// its own. Both are owner-only, and both go when the ownership is let go.
    @Test func anOwnershipIsAcpxsMarkerBesideFsSafesGuard() async throws {
        try await withIsolatedStore {
            let held = try SessionOwnership.importAdmission()
            let marker = ACPXPaths.sessionsDir.appendingPathComponent(".import-admission.lock").path
            let owner = try #require(AcpxLockOwner.current.birth)
            let identity = "\"processIdentity\": {\n    \"kind\": \"posix-lstart\",\n    \"value\": \"\(owner)\"\n  }"
            let written = try String(contentsOfFile: marker, encoding: .utf8)
            let prefix = "{\n  \"pid\": \(getpid()),\n  \(identity),\n  \"created_at\": \""
            #expect(written.hasPrefix(prefix))
            #expect(written.hasSuffix("Z\"\n}\n"))
            let guarded = try String(contentsOfFile: marker + ".guard", encoding: .utf8)
            let payload = "{\n  \"pid\": \(getpid()),\n  \(identity)\n}\n"
            #expect(guarded.hasPrefix(payload + String(repeating: "\t", count: 8)))
            let token = guarded.dropFirst(payload.count + 8)
            #expect(token.count == 129 && token.hasSuffix("\n"))
            #expect(token.dropLast().allSatisfy { $0 == "\t" || $0 == " " })
            #expect(try Self.mode(of: marker) == 0o600)
            #expect(try Self.mode(of: marker + ".guard") == 0o600)

            try held.release()
            #expect(!FileManager.default.fileExists(atPath: marker))
            #expect(!FileManager.default.fileExists(atPath: marker + ".guard"))
            let left = try FileManager.default.contentsOfDirectory(atPath: ACPXPaths.sessionsDir.path)
            #expect(!left.contains { $0.hasPrefix("session-turn-") })
        }
    }

    /// A scope's marker is named as acpx names it: the SHA-256 of `JSON.stringify` of its agent
    /// command, absolute directory and trimmed name (`null` without one) — digests from node.
    @Test func aScopesMarkerIsNamedAsAcpxNamesIt() async throws {
        try await withIsolatedStore {
            let plain = SessionOwnership.scopeMarker(agentCommand: "codex", cwd: "/tmp/work/", name: "  ")
            #expect(plain.lastPathComponent
                == "ensure%3A669ce7798d4c5f79ec203630450c24319b6f80684a1c6d62122247ea15005b94.stream.lock")
            let named = SessionOwnership.scopeMarker(
                agentCommand: "npx -y @zed-industries/claude-code-acp", cwd: "/Users/x/My \"Proj\"", name: "\treview\n")
            #expect(named.lastPathComponent
                == "ensure%3A837e4a8da891daa8534b52f17b112ea344afbd0c0a13d3f36bac6ce6e6a42259.stream.lock")
            #expect(plain.deletingLastPathComponent().path == ACPXPaths.sessionsDir.path)
        }
    }

    /// A birth is written as acpx reads one on macOS: `ps -o lstart=` under `TZ=UTC`, to the second.
    @Test func aBirthIsWhatAcpxReadsOfIt() throws {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(getpid())", "-o", "lstart="]
        ps.environment = ["TZ": "UTC", "LC_ALL": "C"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let spaced = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let started = try #require(formatter.date(from: spaced))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(AcpxLockOwner.birth(of: getpid()) == iso.string(from: started))
    }

    /// Whether an owner has exited, as acpx's `hasExited` decides it.
    @Test func anOwnerHasExitedOnlyOnceItIsGone() throws {
        let child = try Self.sleeper()
        defer { child.terminate() }
        let pid = child.processIdentifier
        let birth = try #require(AcpxLockOwner.birth(of: pid))
        let dead = try Self.deadPid()
        func owner(_ pid: Int32, _ identity: String?) -> WireJSON {
            var members = [WireJSON.Member("pid", .number(Double(pid)))]
            if let parsed = identity.flatMap({ WireJSON(parsing: $0) }) {
                members.append(.init("processIdentity", parsed))
            }
            return .object(members)
        }
        let lstart = { (value: String) in #"{"kind":"posix-lstart","value":"\#(value)"}"# }
        #expect(!AcpxLockOwner.hasExited(owner(pid, lstart(birth))))
        #expect(AcpxLockOwner.hasExited(owner(pid, lstart("2001-02-03T04:05:06.000Z"))))
        #expect(AcpxLockOwner.hasExited(owner(dead, lstart(birth))))
        // Without a birth, or with one acpx would not take, only a pid no process has.
        #expect(!AcpxLockOwner.hasExited(owner(pid, nil)))
        #expect(AcpxLockOwner.hasExited(owner(dead, nil)))
        #expect(!AcpxLockOwner.hasExited(owner(pid, lstart("2001-02-03T04:05:06.500Z"))))
        #expect(AcpxLockOwner.hasExited(owner(dead, lstart("2001-02-03T04:05:06.500Z"))))
        // A birth only another platform reads says nothing, dead pid or not.
        let linux = #"{"kind":"linux-proc","bootId":"0123abcd-0123-4567-89ab-0123456789ab","#
            + #""pidNamespace":"pid:[4026531836]","timeNamespace":"unsupported","startTicks":"42"}"#
        #expect(!AcpxLockOwner.hasExited(owner(dead, linux)))
        let windows = #"{"kind":"windows-creation","value":"2001-02-03T04:05:06.1234567Z"}"#
        #expect(!AcpxLockOwner.hasExited(owner(dead, windows)))
        // No pid acpx would take: never exited.
        #expect(!AcpxLockOwner.hasExited(.object([])))
        #expect(!AcpxLockOwner.hasExited(.object([.init("pid", .number(-1))])))
        #expect(!AcpxLockOwner.hasExited(.object([.init("pid", .text("\(dead)"))])))
        #expect(!AcpxLockOwner.hasExited(nil))
        // This process never has.
        #expect(!AcpxLockOwner.hasExited(owner(getpid(), nil)))
    }

    /// An ownership a live process holds — written as acpx writes one — is not taken.
    @Test func aLiveHoldersOwnershipIsNotTaken() async throws {
        try await withIsolatedStore {
            let child = try Self.sleeper()
            defer { child.terminate() }
            let marker = try Self.holdAsForeign(".import-admission.lock", by: child.processIdentifier)
            let before = try Self.contents(marker)
            #expect(try Self.tryOnce(marker) == nil)
            #expect(try Self.contents(marker) == before)
        }
    }

    /// One whose owner is gone — or was born at another time — is taken back.
    @Test(arguments: [false, true])
    func aGoneHoldersOwnershipIsTakenBack(bornElsewhen: Bool) async throws {
        try await withIsolatedStore {
            let child = try Self.sleeper()
            defer { child.terminate() }
            // A reaped process has no birth to read: any stands in.
            let pid = bornElsewhen ? child.processIdentifier : try Self.deadPid()
            let marker = try Self.holdAsForeign(".import-admission.lock", by: pid, birth: "2001-02-03T04:05:06.000Z")
            let held = try #require(try Self.tryOnce(marker))
            #expect(try String(contentsOfFile: marker, encoding: .utf8).contains("\"pid\": \(getpid()),"))
            #expect(try String(contentsOfFile: marker + ".guard", encoding: .utf8).contains("\"pid\": \(getpid()),"))
            try held.release()
        }
    }

    /// A marker that names no owner — one still being written — is left alone for 15 seconds
    /// from its last change, then taken back; a guard that cannot be read is held for good, as
    /// fs-safe holds one; and a reclaim under way keeps every other taker off.
    @Test func whatNamesNoOwnerIsLeftAlone() async throws {
        try await withIsolatedStore {
            try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
            let marker = ACPXPaths.sessionsDir.appendingPathComponent(".import-admission.lock").path
            try Data("{\"pi".utf8).write(to: URL(fileURLWithPath: marker))
            #expect(try Self.tryOnce(marker) == nil)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-16)], ofItemAtPath: marker)
            let taken = try #require(try Self.tryOnce(marker))
            try taken.release()

            try Data("not json".utf8).write(to: URL(fileURLWithPath: marker + ".guard"))
            #expect(try Self.tryOnce(marker) == nil)
            try FileManager.default.removeItem(atPath: marker + ".guard")

            try FileManager.default.createDirectory(
                atPath: marker + ".guard.reclaim", withIntermediateDirectories: false)
            #expect(try Self.tryOnce(marker) == nil)
            try FileManager.default.removeItem(atPath: marker + ".guard.reclaim")
            try #require(try Self.tryOnce(marker)).release()
        }
    }

    /// Of two imports into one scope, only one takes it (#781, #784): one that waits for the
    /// scope's ownership, which another holds, finds the scope taken by an import that went
    /// first meanwhile.
    @Test func anImportWaitsForTheScopeAndFindsItTaken() async throws {
        let fixture = try SessionArchiveTests.fixture()
        try await withIsolatedStore {
            let archive = try SessionArchiveTests.directory() + "/archive.json"
            try SessionArchiveTests.writeArchive(fixture, to: archive)
            let cwd = try SessionArchiveTests.directory()
            let child = try Self.sleeper()
            defer { child.terminate() }
            // The archive's session is named `alpha`, which the import keeps.
            let scope = SessionOwnership.scopeMarker(agentCommand: fixture.command, cwd: cwd, name: "alpha")
            _ = try Self.holdAsForeign(scope.lastPathComponent, by: child.processIdentifier)
            let first = ImportedBox()
            SessionOwnership.waiting = { path in
                guard path.hasSuffix(scope.lastPathComponent), !first.done else { return }
                first.done = true
                // The holder goes, and another import takes the scope first.
                child.terminate()
                child.waitUntilExit()
                first.recordId = try? SessionArchive.importArchive(
                    at: archive, name: nil, cwd: cwd, expectedAgentName: "probe",
                    expectedAgentCommand: fixture.command).recordId
            }
            defer { SessionOwnership.waiting = nil }

            #expect(throws: SessionArchive.Refusal.self) {
                try SessionArchive.importArchive(
                    at: archive, name: nil, cwd: cwd, expectedAgentName: "probe", expectedAgentCommand: fixture.command)
            }
            #expect(first.recordId != nil)
            #expect(SessionStore.listSessions().count == 1)
        }
    }

    /// `sessions ensure` finds or makes its session under the scope's ownership (#784): one that
    /// waits for it, held by another, keeps the session made meanwhile rather than make one.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func anEnsureWaitsForTheScopeAndKeepsTheSessionMadeMeanwhile() async throws {
        let agent = try #require(mockCommand())
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            // A session made first and set aside: it comes back while the ensure waits.
            let made = await Self.acpx(
                ["--format", "quiet", "sessions", "new"], agent: agent, cwd: directory, daemon: daemon)
            let id = made.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = try #require(SessionStore.loadRecord(id))
            try FileManager.default.removeItem(at: ACPXPaths.sessionRecordPath(id))
            let child = try Self.sleeper()
            defer { child.terminate() }
            let scope = SessionOwnership.scopeMarker(agentCommand: record.agentCommand, cwd: record.cwd, name: nil)
            _ = try Self.holdAsForeign(scope.lastPathComponent, by: child.processIdentifier)
            let comeBack = ImportedBox()
            SessionOwnership.waiting = { path in
                guard path.hasSuffix(scope.lastPathComponent), !comeBack.done else { return }
                comeBack.done = true
                child.terminate()
                child.waitUntilExit()
                try? SessionStore.writeRecord(record)
            }
            defer { SessionOwnership.waiting = nil }

            let ensured = await Self.acpx(
                ["--format", "json", "sessions", "ensure"], agent: agent, cwd: directory, daemon: daemon)
            #expect(ensured.code == 0)
            #expect(ensured.out.contains(#""created":false,"acpxRecordId":"\#(id)""#))
            #expect(SessionStore.listSessions().map(\.acpxRecordId) == [id])
            await backend.releaseAll()
        }
    }

    // MARK: - Support

    /// `acpx --approve-all --agent <agent> --cwd <cwd> <args>` against the stand-in `daemon`: its
    /// exit code and what it wrote to stdout.
    static func acpx(
        _ args: [String], agent: String, cwd: URL, daemon: MCPServerConfig
    ) async -> (code: Int32, out: String) {
        let capture = Console.Capture()
        let code: Int32 = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: DaemonClient.$standIn.withValue(daemon) {
                    Console.$capture.withValue(capture) {
                        runCommandLine(["--approve-all", "--agent", agent, "--cwd", cwd.path] + args)
                    }
                })
            }.start()
        }
        return (code, capture.out)
    }

    /// A process that runs until it is ended.
    static func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    /// A pid no process has: one that ran and was reaped.
    static func deadPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// Hold the ownership marked `name` in the sessions directory as acpx would for `pid`: its
    /// marker, and fs-safe's guard with a token. The birth is the process's own unless given.
    static func holdAsForeign(_ name: String, by pid: Int32, birth: String? = nil) throws -> String {
        try FileManager.default.createDirectory(at: ACPXPaths.sessionsDir, withIntermediateDirectories: true)
        let marker = ACPXPaths.sessionsDir.appendingPathComponent(name).path
        let identity = try #require(birth ?? AcpxLockOwner.birth(of: pid))
        let owner = "{\n  \"pid\": \(pid),\n  \"processIdentity\": {\n    \"kind\": \"posix-lstart\",\n"
            + "    \"value\": \"\(identity)\"\n  }"
        try Data((owner + ",\n  \"created_at\": \"2026-09-28T00:00:00.000Z\"\n}\n").utf8)
            .write(to: URL(fileURLWithPath: marker))
        let token = String(repeating: "\t", count: 8) + String((0..<128).map { $0 % 3 == 0 ? "\t" : " " })
        try Data((owner + "\n}\n" + token + "\n").utf8).write(to: URL(fileURLWithPath: marker + ".guard"))
        return marker
    }

    /// One try at the ownership `marker` names, as this process.
    static func tryOnce(_ marker: String) throws -> SessionOwnership? {
        try SessionOwnership.tryAcquire(
            SessionOwnership.canonical(URL(fileURLWithPath: marker)),
            payload: SessionOwnership.markerPayload(for: .current), owner: .current)
    }

    static func contents(_ marker: String) throws -> [String] {
        try [marker, marker + ".guard"].map { try String(contentsOfFile: $0, encoding: .utf8) }
    }

    static func mode(of path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0) & 0o777
    }
}

/// What the import that went first made.
private final class ImportedBox: @unchecked Sendable {
    var done = false
    var recordId: String?
}
