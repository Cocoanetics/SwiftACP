@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A `set` whose reply lists no options is an acknowledgement, as acpx 0.19.4 takes it
/// (#778, openclaw/acpx#809): the record keeps its catalog, the option at its new value —
/// a model's as the id that went out (openclaw/acpx#807) — and `set` reports that catalog
/// (`printSetConfigOptionResultByFormat`) rather than none.
extension DaemonToolsTests {
    private func field(_ option: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let fields) = option else { return nil }
        return fields[key]
    }

    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aSetTheAgentOnlyAcknowledgesReportsTheRecordsOptions() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_ACK_CONFIG=1 ")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let result = try await daemon.setConfigOption(sessionId: session.id, configId: "effort", value: "high")
            #expect(result.configOptions == nil)

            let record = try #require(SessionStore.loadRecord(session.id))
            let reported = ControlCommand.reportedOptions(result, record: record).arrayValue ?? []
            #expect(reported.compactMap { field($0, "id") } == [.string("model"), .string("effort")])
            let effort = reported.first { field($0, "id") == .string("effort") }
            #expect(effort.flatMap { field($0, "currentValue") } == .string("high"))
            #expect(record.acpx?.desiredConfigOptions?["effort"] == "high")
            await daemon.releaseAll()
        }
    }

    /// A reply that reports the options is what `set` reports, whatever the record holds.
    @Test func aSetReportsTheOptionsTheAgentReported() {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: "r", acpSessionId: "r", agentCommand: "agent", cwd: "/tmp", createdAt: now, lastUsedAt: now)
        var acpx = SessionAcpxState()
        acpx.configOptions = .array([.object(["id": .string("saved")])])
        record.acpx = acpx
        let reported: [JSONValue] = [.object(["id": .string("reported")])]
        #expect(ControlCommand.reportedOptions(
            SessionControlResult(resumed: false, configOptions: reported), record: record) == .array(reported))
        #expect(ControlCommand.reportedOptions(SessionControlResult(resumed: false), record: record)
            .arrayValue?.first.flatMap { field($0, "id") } == .string("saved"))
        // Options that are no list are none (`Array.isArray`, acpx 0.19.4, openclaw/acpx#809):
        // the record's again.
        for raw in [JSONValue.null, .string("oops"), .integer(5)] {
            #expect(ControlCommand.reportedOptions(SessionControlResult(resumed: false, rawConfigOptions: raw),
                record: record).arrayValue?.first.flatMap { field($0, "id") } == .string("saved"), "\(raw)")
        }
        record.acpx = nil
        #expect(ControlCommand.reportedOptions(SessionControlResult(resumed: false), record: record) == .array([]))
    }

    /// The count `set` prints is the options' `length`: a list's entries, and none for
    /// anything else — which `set` no longer reports (acpx 0.19.4, openclaw/acpx#809).
    @Test func aSetCountsTheOptionsAsAcpxDoes() {
        #expect(ControlCommand.optionCount(.array([.null, .null])) == 2)
        #expect(ControlCommand.optionCount(.string("oops")) == 0)
        #expect(ControlCommand.optionCount(.integer(5)) == 0)
        #expect(ControlCommand.optionCount(.object([:])) == 0)
    }

    /// acpx 0.19.4's `opaque-config.test.ts` (openclaw/acpx#809): a reply whose options are no
    /// list — none (a `null` or `{}` reply), `null`, a number, a string, an object —
    /// acknowledges a selection without replacing the catalog or dropping the saved
    /// selections, for a plain option and then for the model.
    @Test(arguments: [nil, JSONValue.null, .integer(5), .string("oops"), .object([:])])
    func optionsThatAreNoListAcknowledgeWithoutReplacingTheCatalog(_ raw: JSONValue?) {
        var state = SessionAcpxState()
        state.configOptions = .array([
            .object([
                "id": .string("model"), "type": .string("select"), "category": .string("model"),
                "currentValue": .string("m1"),
                "options": .array([
                    .object(["value": .string("m1"), "name": .string("One")]),
                    .object(["value": .string("m2"), "name": .string("Two")])
                ])
            ]),
            .object(["id": .string("effort"), "type": .string("select"), "currentValue": .string("low")])
        ])
        state.desiredConfigOptions = ["effort": "low"]
        var response = SetSessionConfigOptionResponse()
        response.rawConfigOptions = raw
        ModelSupport.applyConfigOptionSelection("effort", value: "high", response: response, to: &state)
        #expect(state.configOptions?.arrayValue?.map { field($0, "currentValue") } == [.string("m1"), .string("high")])
        #expect(state.desiredConfigOptions == ["effort": "high"])
        ModelSupport.applyModelSelection("m2", response: response, to: &state)
        #expect(state.currentModelId == "m2")
        #expect(state.configOptions?.arrayValue?.map { field($0, "currentValue") } == [.string("m2"), .string("high")])
        #expect(state.desiredConfigOptions == ["effort": "high"])
    }

    /// A session on `model-agent.py` started through a program named `cursor-agent`, so the
    /// adapter's alias rule applies, advertising `gpt-5[thinking]` beside `m1` and answering
    /// each selection with `{}`. Returns the session's id and the request log, emptied.
    private func cursorSession() async throws -> (id: String, log: URL) {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/model-agent.py")
        try FileManager.default.createDirectory(at: ACPXPaths.baseDir, withIntermediateDirectories: true)
        let log = ACPXPaths.baseDir.appendingPathComponent("requests.ndjson")
        let wrapper = ACPXPaths.baseDir.appendingPathComponent("cursor-agent")
        try """
            #!/bin/sh
            exec /usr/bin/env MODEL_AGENT_LOG='\(log.path)' MODEL_AGENT_MODELS='m1,gpt-5[thinking]' \
              MODEL_AGENT_EMPTY_REPLIES=1 '\(python)' '\(fixture.path)'

            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let record = try await SessionEngine.createSession(
            agentCommand: wrapper.path, cwd: NSTemporaryDirectory(), name: nil, permission: .approveAll,
            authCredentials: [:], authPolicy: "skip")
        try "".write(to: log, atomically: true, encoding: .utf8)
        return (record.acpxRecordId, log)
    }

    /// acpx 0.19.4 (openclaw/acpx#807, `owned-controls.test.ts`): a model set by a Cursor alias
    /// and acknowledged with `{}` goes out as the advertised id, which the record keeps current
    /// and as the option's value, while `session_options` keeps the alias — through the model
    /// control and through its option alike.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: [false, true])
    func anAcknowledgedAliasKeepsTheResolvedId(throughOption: Bool) async throws {
        try await withIsolatedStore {
            let (id, log) = try await cursorSession()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            if throughOption {
                _ = try await daemon.setConfigOption(sessionId: id, configId: "model", value: "gpt-5")
            } else {
                _ = try await daemon.setModel(sessionId: id, modelId: "gpt-5")
            }
            let acpx = try #require(SessionStore.loadRecord(id)?.acpx)
            await daemon.releaseAll()
            #expect(try Self.modelAgentRequests(log)
                == ["session/new", "session/set_config_option model=gpt-5[thinking]"])
            #expect(acpx.currentModelId == "gpt-5[thinking]")
            #expect(acpx.configOptions?.arrayValue?.first.flatMap { field($0, "currentValue") }
                == .string("gpt-5[thinking]"))
            #expect(acpx.sessionOptions?.model == "gpt-5")
        }
    }

    /// acpx's acknowledgement sets the first option with the id (`find`), not every one.
    @Test func anAcknowledgementSetsTheFirstOptionWithItsId() {
        var state = SessionAcpxState()
        state.configOptions = .array([
            .object(["id": .string("effort"), "currentValue": .string("low")]),
            .object(["id": .string("effort"), "currentValue": .string("low")])
        ])
        ModelSupport.applyConfigOptionSelection(
            "effort", value: "high", response: SetSessionConfigOptionResponse(), to: &state)
        guard case .array(let options)? = state.configOptions else {
            Issue.record("the catalog is gone")
            return
        }
        #expect(options.map { field($0, "currentValue") } == [.string("high"), .string("low")])
    }
}
