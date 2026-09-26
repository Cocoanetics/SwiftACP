@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// The runner's rules that need no flow to run: acpx's `runtime-support.ts` identifiers,
/// `graph.ts` routing and `toInlineOutput`.
struct FlowRuntimeSupportTests {
    /// acpx: "createRunId slugifies flow names without regex backtracking".
    @Test func aRunIdSlugifiesTheFlowName() {
        #expect(FlowRuntimeSupport.slugifyAsciiIdPart("Fixture Interrupt!") == "fixture-interrupt")
        #expect(FlowRuntimeSupport.slugifyAsciiIdPart("__A__b--") == "a-b")
        #expect(FlowRuntimeSupport.slugifyAsciiIdPart("ünï") == "n")
        #expect(FlowRuntimeSupport.slugifyAsciiIdPart("😀x") == "x")
        let uuid = UUID(uuidString: "D7EB6EA7-0000-4000-8000-000000000000")!
        #expect(FlowRuntimeSupport.runId(flowName: "My Flow", now: "2026-09-26T09:05:31.772Z", uuid: uuid)
            == "2026-09-26T090531772Z-my-flow-d7eb6ea7")
    }

    @Test func attemptsAreCountedPerNode() {
        var counts: [String: Int] = [:]
        #expect(FlowRuntimeSupport.nextAttemptId(&counts, nodeId: "a") == "a#1")
        #expect(FlowRuntimeSupport.nextAttemptId(&counts, nodeId: "b") == "b#1")
        #expect(FlowRuntimeSupport.nextAttemptId(&counts, nodeId: "a") == "a#2")
    }

    private func route(_ edge: String, _ output: String?, outcome: String = "ok") throws -> String? {
        let result: WireJSON = .object([WireJSON.Member("outcome", .text(outcome))])
        let value: FlowValue = try output.map { .json(try WireJSON.parse($0)) } ?? .undefined
        return try FlowGraph.resolveNext(
            [try WireJSON.parse(edge)], from: "a", output: value, result: result, outcome: outcome)
    }

    @Test func aSwitchRoutesOnTheScalarItReads() throws {
        let edge = #"{"from":"a","switch":{"on":"$.route","cases":{"x":"b","1.5":"c","true":"d","2":"e"}}}"#
        #expect(try route(edge, #"{"route":"x"}"#) == "b")
        #expect(try route(edge, #"{"route":1.5}"#) == "c")
        #expect(try route(edge, #"{"route":true}"#) == "d")
        let length = #"{"from":"a","switch":{"on":"$.items.length","cases":{"2":"b"}}}"#
        #expect(try route(length, #"{"items":[1,2]}"#) == "b")
        let index = #"{"from":"a","switch":{"on":"$output.items.1","cases":{"y":"b"}}}"#
        #expect(try route(index, #"{"items":["x","y"]}"#) == "b")
        #expect(throws: FlowGraph.RoutingError.self) { try route(edge, #"{"route":"zzz"}"#) }
        // A string has no members to read: `$.text.length` is undefined, not a length.
        #expect(throws: FlowGraph.RoutingError.self) {
            try route(#"{"from":"a","switch":{"on":"$.text.length","cases":{"3":"b"}}}"#, #"{"text":"abc"}"#)
        }
    }

    @Test func aFailedStepRoutesOnlyByItsResult() throws {
        #expect(try route(#"{"from":"a","to":"b"}"#, nil, outcome: "failed") == nil)
        #expect(try route(#"{"from":"a","switch":{"on":"$.route","cases":{"x":"b"}}}"#, nil, outcome: "failed") == nil)
        #expect(try route(#"{"from":"a","switch":{"on":"$result.outcome","cases":{"failed":"b"}}}"#, nil,
            outcome: "failed") == "b")
    }

    /// acpx's `toInlineOutput`: short and on one line inline, else an artifact.
    @Test func shortOutputsGoInline() {
        let short = String(repeating: "x", count: 200)
        #expect(FlowRunner.inlineOutput(.json(.text(short))) == .text(short))
        #expect(FlowRunner.inlineOutput(.json(.text(short + "x"))) == nil)
        #expect(FlowRunner.inlineOutput(.json(.text("a\nb"))) == nil)
        #expect(FlowRunner.inlineOutput(.json(.number(5))) == .number(5))
        #expect(FlowRunner.inlineOutput(.unrepresentable) == nil)
        let items = WireJSON.array((0..<30).map { .text("item-\($0)") })
        #expect(FlowRunner.inlineOutput(.json(items)) == nil)
    }

    /// Node runs whatever the host's cache holds, so none of it is taken on trust: scripts
    /// changed or turned into links are written again, others' write access to the
    /// directory is taken away, and a cache that is a link is refused (a Codex finding).
    @Test func theHostsScriptsAreTakenOnlyAsThisCLIWroteThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try FlowHostFiles.install(root: root)
        let directory = URL(fileURLWithPath: installed.host).deletingLastPathComponent()
        let expected = try Data(contentsOf: URL(fileURLWithPath: installed.host))
        #expect(expected == Data(FlowHostScripts.host.utf8))
        #expect(try mode(directory) == 0o700)
        // Owner-only whatever the umask: no one else may change what Node will run.
        for script in [installed.host, installed.runtime, installed.sucrase] {
            #expect(try mode(URL(fileURLWithPath: script)) == 0o600, "\(script)")
        }

        try Data("process.exit(66)".utf8).write(to: URL(fileURLWithPath: installed.host))
        let decoy = root.appendingPathComponent("decoy.mjs")
        try Data(FlowHostScripts.runtime.utf8).write(to: decoy)
        try FileManager.default.removeItem(atPath: installed.runtime)
        try FileManager.default.createSymbolicLink(atPath: installed.runtime, withDestinationPath: decoy.path)
        chmod(directory.path, 0o777)
        _ = try FlowHostFiles.install(root: root)
        #expect(try Data(contentsOf: URL(fileURLWithPath: installed.host)) == expected)
        let runtime = try FileManager.default.attributesOfItem(atPath: installed.runtime)
        #expect(runtime[.type] as? FileAttributeType == .typeRegular)
        #expect(try mode(URL(fileURLWithPath: installed.host)) == 0o600)
        #expect(try mode(directory) & 0o022 == 0)

        let linked = FileManager.default.temporaryDirectory.appendingPathComponent("flow-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linked) }
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        #expect(throws: FlowHostFiles.UnsafeDirectory.self) { _ = try FlowHostFiles.install(root: linked) }
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }
}
