@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// A `set` whose reply reports no options is an acknowledgement, as acpx 0.19.3 takes it
/// (#778): the record keeps its catalog, the option at its new value, and `set` reports
/// that catalog (`printSetConfigOptionResultByFormat`) rather than none.
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
        // `null`, as acpx's `??` takes it, falls back to the record too.
        #expect(ControlCommand.reportedOptions(SessionControlResult(resumed: false, rawConfigOptions: .null),
            record: record).arrayValue?.first.flatMap { field($0, "id") } == .string("saved"))
        #expect(ControlCommand.reportedOptions(
            SessionControlResult(resumed: false, rawConfigOptions: .string("oops")), record: record) == .string("oops"))
        record.acpx = nil
        #expect(ControlCommand.reportedOptions(SessionControlResult(resumed: false), record: record) == .array([]))
    }

    /// The count `set` prints is the options' `length`: a string's UTF-16 code units, as
    /// acpx counts a string reply, and none for anything else that is no list.
    @Test func aSetCountsTheOptionsAsAcpxDoes() {
        #expect(ControlCommand.optionCount(.array([.null, .null])) == 2)
        #expect(ControlCommand.optionCount(.string("oops")) == 4)
        #expect(ControlCommand.optionCount(.string("é😀")) == 3)
        #expect(ControlCommand.optionCount(.integer(5)) == 0)
        #expect(ControlCommand.optionCount(.object([:])) == 0)
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
