@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// Destructive CLI commands run only against this test's isolated session store.
struct SessionsPruneSafetyTests {
    private static let agent = "/opt/agents/prune-safety"
    private static let old = "2020-01-01T00:00:00.000Z"

    private func seed() throws {
        for id in ["selected", "other-agent", "recent", "open", "fallback"] {
            let date = id == "recent" ? nowISO() : Self.old
            var record = SessionRecord(
                acpxRecordId: id, acpSessionId: "shared-native-id",
                agentCommand: id == "other-agent" ? "/opt/agents/other" : Self.agent,
                cwd: "/tmp/prune-safety", createdAt: date, lastUsedAt: date)
            record.closed = id != "open"
            record.closedAt = id == "fallback" ? nil : date
            try SessionStore.writeRecord(record)
            for suffix in ["stream.ndjson", "stream.lock", "stream.7.ndjson"] {
                try Data("history for \(id)".utf8).write(
                    to: ACPXPaths.sessionsDir.appendingPathComponent("\(id).\(suffix)"))
            }
        }
    }

    private func snapshot() throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(
            at: ACPXPaths.sessionsDir, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func run(
        _ arguments: [String], format: String = "json", jsonStrict: Bool = false
    ) async -> CLIParityTests.Run {
        var leading = ["--agent", Self.agent, "--format", format]
        if jsonStrict { leading.append("--json-strict") }
        return await CLIParityTests.run(leading + ["sessions"] + arguments)
    }

    @Test func pruneWithoutYesDeletesNothing() async throws {
        try await withIsolatedStore {
            try seed()
            let before = try snapshot()
            let result = await run(["prune", "--include-history"])
            #expect(result.code == ExitCodes.error)
            #expect(result.err.contains("--yes"))
            #expect(result.out.contains("selected"))
            #expect(result.out.contains("fallback"))
            #expect(try snapshot() == before)
        }
    }

    @Test(arguments: [false, true]) func dryRunNeverDeletes(confirmed: Bool) async throws {
        try await withIsolatedStore {
            try seed()
            let before = try snapshot()
            let result = await run(["prune", "--dry-run", "--include-history"] + (confirmed ? ["--yes"] : []))
            #expect(result.code == ExitCodes.success)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
            #expect(Set(json["pruned"] as? [String] ?? []) == ["selected", "recent", "fallback"])
            #expect(json["dryRun"] as? Bool == true)
            #expect(json["bytesFreed"] as? Int == 0)
            #expect(try snapshot() == before)
        }
    }

    @Test(arguments: [["--before", "2021-01-01"], ["--older-than", "30"]])
    func confirmedPrunePreservesAgentAgeAndClosedBoundaries(age: [String]) async throws {
        try await withIsolatedStore {
            try seed()
            let before = try snapshot()
            let result = await run(["prune", "--yes", "--include-history"] + age)
            #expect(result.code == ExitCodes.success)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
            #expect(Set(json["pruned"] as? [String] ?? []) == ["selected", "fallback"])
            #expect(result.err.contains("selected"))
            #expect(result.err.contains("fallback"))
            let expected = before.filter { !$0.key.hasPrefix("selected.") && !$0.key.hasPrefix("fallback.") }
            #expect(try snapshot() == expected)
        }
    }

    /// `--json-strict` must suppress prune's candidate / confirmation banners on stderr
    /// while still emitting the JSON result on stdout (Codex review on #320).
    @Test(arguments: [false, true])
    func jsonStrictPruneEmitsNoNonJSONStderr(confirmed: Bool) async throws {
        try await withIsolatedStore {
            try seed()
            let before = try snapshot()
            let result = await run(
                ["prune", "--include-history", "--before", "2021-01-01"] + (confirmed ? ["--yes"] : []),
                jsonStrict: true)
            #expect(result.err.isEmpty, "strict mode leaked stderr: \(result.err)")
            let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
            #expect(Set(json["pruned"] as? [String] ?? []) == ["selected", "fallback"])
            if confirmed {
                #expect(result.code == ExitCodes.success)
                #expect(json["dryRun"] as? Bool == false)
                let expected = before.filter { !$0.key.hasPrefix("selected.") && !$0.key.hasPrefix("fallback.") }
                #expect(try snapshot() == expected)
            } else {
                #expect(result.code == ExitCodes.error)
                #expect(json["dryRun"] as? Bool == true)
                #expect(try snapshot() == before)
            }
        }
    }

    @Test(arguments: [false, true], ["selected", "open"])
    func removeDeletesOnlyItsExactRecord(includeHistory: Bool, id: String) async throws {
        try await withIsolatedStore {
            try seed()
            let before = try snapshot()
            let result = await run(["remove", id] + (includeHistory ? ["--include-history"] : []))
            #expect(result.code == ExitCodes.success, "\(result.err)")
            let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
            #expect(json["acpxRecordId"] as? String == id)
            let expected = before.filter {
                $0.key != "\(id).json" && !(includeHistory && $0.key.hasPrefix("\(id).stream."))
            }
            #expect(try snapshot() == expected)
        }
    }

    @Test(arguments: ["missing", "shared-native-id", "lected", "", "  "])
    func removeRefusesAnythingOtherThanAnExactRecordId(id: String) async throws {
        try await withIsolatedStore {
            try seed()
            let before = try snapshot()
            let result = await run(["remove", id])
            #expect(result.code != ExitCodes.success)
            #expect(try snapshot() == before)
        }
    }

    @Test func removeRequiresAnIdAndHelpExplainsConfirmation() async {
        await withIsolatedStore {
            let missing = await run(["remove"])
            #expect(missing.code != ExitCodes.success)
            let help = await run(["prune", "--help"])
            #expect(help.out.contains("--yes"))
            let removeHelp = await run(["remove", "--help"])
            #expect(removeHelp.out.contains("<id>"))
        }
    }
}
