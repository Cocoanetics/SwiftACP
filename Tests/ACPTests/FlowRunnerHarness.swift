@testable import ACPXCore
@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// Runs a flow module with the runner itself and the flow's code in the Node host, as
/// `flow run` runs it, keeping the bundle in a directory of its own — so nothing
/// process-wide is touched, and no store isolation is needed.
enum FlowRunnerHarness {
    /// A finished run: `err` and `code` are what the CLI would report of its failure;
    /// `tracked`, what the host still held for attempts once it was over, and
    /// `pendingRequests`, how many of its requests the runner still waited on, when asked;
    /// `probed`, what a probe of the runner found once the run was over.
    struct Run {
        var err = ""
        var code: Int32 = 0
        var state: WireJSON?
        var trace: [WireJSON] = []
        var tracked: WireJSON?
        var pendingRequests: Int?
        var probed: String?
        /// The bundle's files by path, and the directory the flow ran in.
        var files: [String: String] = [:]
        var flowDir = ""
    }

    /// Run a flow module — `body` after acpx's helpers are imported, or as it is without
    /// `prelude` — with `input`, beside `files`. With `tracking`, the host is asked what it
    /// holds for attempts once the run is over: not of a host whose callback holds its
    /// event loop, which cannot answer. `probe` is handed the runner once the run is over.
    /// `sessions` runs its ACP nodes' turns, with the agent named `mock` — launched with
    /// `agentCommand` — in the flow's directory for every profile; `errorOutput` is where they
    /// report on stderr.
    /// `runnerReady` is handed the runner before the run starts.
    static func run(
        _ body: String, extension ext: String = "mjs", files: [String: String] = [:],
        input: WireJSON = .object([WireJSON.Member]()), tracking: Bool = false, prelude: Bool = true,
        probe: (@Sendable (FlowRunner) async -> String)? = nil, sessions: (any FlowSessionRunner)? = nil,
        agentCommand: String = "mock-agent", errorOutput: @escaping @Sendable (String) -> Void = { _ in },
        runnerReady: (@Sendable (FlowRunner) -> Void)? = nil
    ) async throws -> Run {
        let node = try #require(AgentRegistry.which("node"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, content) in files {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let flowFile = dir.appendingPathComponent("test.flow.\(ext)")
        let imports = "import { defineFlow, acp, action, checkpoint, compute, shell } from \"acpx/flows\";\n"
        try ((prelude ? imports : "") + body).write(to: flowFile, atomically: true, encoding: .utf8)
        let runs = dir.appendingPathComponent("runs")
        let host = try FlowHost.start(node: node, cwd: dir.path, environment: ProcessInfo.processInfo.environment)
        var run = Run()
        run.flowDir = dir.path
        let cwd = dir.path
        let runner = FlowRunner(host: host, options: FlowRunner.Options(
            outputRoot: runs, defaultCwd: cwd,
            resolveAgent: { _ in FlowAgent(agentName: "mock", agentCommand: agentCommand, agentArgv: nil, cwd: cwd) },
            sessions: sessions, errorOutput: errorOutput))
        runnerReady?(runner)
        do {
            let loaded = try await host.request("flow/load", .object([WireJSON.Member("path", .text(flowFile.path))]))
            let flow = try FlowDescription(loaded: loaded ?? .null)
            _ = try await runner.run(flow, input: input, flowPath: flowFile.path)
        } catch {
            run.err = TurnFailureText.message(of: error)
            run.code = error is FlowTimeoutError ? 3 : 1
        }
        if let probe { run.probed = await probe(runner) }
        if tracking {
            run.tracked = try? await host.request("host/tracked")
            run.pendingRequests = host.pendingRequestCount
        }
        await host.stop()
        if let name = try? FileManager.default.contentsOfDirectory(atPath: runs.path).first {
            let runDir = runs.appendingPathComponent(name)
            run.state = try? WireJSON.parse(String(
                contentsOf: runDir.appendingPathComponent("projections/run.json"), encoding: .utf8))
            let trace = (try? String(contentsOf: runDir.appendingPathComponent("trace.ndjson"), encoding: .utf8)) ?? ""
            run.trace = trace.split(separator: "\n").compactMap { try? WireJSON.parse(String($0)) }
            let enumerator = FileManager.default.enumerator(atPath: runDir.path)
            while let relative = enumerator?.nextObject() as? String {
                let content = try? String(contentsOf: runDir.appendingPathComponent(relative), encoding: .utf8)
                if let content { run.files[relative] = content }
            }
        }
        return run
    }

    static func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }
}
