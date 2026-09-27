@testable import ACPXCore
@testable import ACPXFlows
@testable import acpx
import CryptoKit
import Foundation
import SwiftACP
import Testing

let pythonAvailable = AgentRegistry.which("python3") != nil

/// ACP nodes in `flow run` as acpx 0.19.3 runs them (#202, step 3), through the CLI with a
/// real agent — the fixture agent `mock-agent.py`, a flow's `mock` profile — each in a
/// store of its own. `FlowAcpRunnerTests` has what the runner alone decides.
@Suite(.serialized) struct FlowAcpRunTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    struct Run {
        var out: String
        var err: String
        var code: Int32
        /// The bundle's files, normalized as the golden fixture is.
        var files: [String: [String: String]] = [:]
        var state: WireJSON?
    }

    /// `flow run` on the fixture flow `name` — or on `body`, after acpx's helpers are
    /// imported — in a directory of its own with the fixture agent `agentScript` as its
    /// `mock` profile, started with `agentEnvironment`, and a `sub` directory. `options` go
    /// before `flow run`, `arguments` after the file. With `interruptWhenLogged`, SIGINT
    /// arrives once the agent logs a request with that text (`MOCK_REQUEST_LOG`).
    private func flowRun(
        _ name: String, body: String? = nil, options: [String] = [], arguments: [String] = [],
        agentScript: String = "mock-agent.py", agentEnvironment: [String: String] = [:],
        interruptWhenLogged: String? = nil
    ) async throws -> Run {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("flow-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        // As the recorder has it: the directory by its real path, which the agent is told.
        let dir = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))))
        let flowFile = dir.appendingPathComponent(name)
        if let body {
            let imports = "import { defineFlow, acp, compute } from \"acpx/flows\";\n"
            try (imports + body).write(to: flowFile, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("flows/\(name)"), to: flowFile)
        }
        let agent = dir.appendingPathComponent(agentScript)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(agentScript), to: agent)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var environment = agentEnvironment
        let source = Interrupts.Source()
        var watch: DispatchSourceRead?
        if let interruptWhenLogged {
            let log = dir.appendingPathComponent("requests.log")
            watch = try Self.fire(source, whenLogged: interruptWhenLogged, at: log)
            environment["MOCK_REQUEST_LOG"] = log.path
        }
        defer { watch?.cancel() }
        // The agent started through a shell when it needs an environment of its own.
        let launch: [(String, WireJSON?)] = environment.isEmpty
            ? [("command", .text("python3")), ("args", .array([.text(agent.path)]))]
            : [("command", .text("/bin/sh")), ("args", .array([.text("-c"), .text(
                environment.sorted { $0.key < $1.key }.map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
                    + " exec python3 '\(agent.path)'")]))]
        let config: WireJSON = .object([("agents", .object([("mock", .object(launch))]))])
        try config.stringified.write(to: dir.appendingPathComponent(".acpxrc.json"), atomically: true, encoding: .utf8)
        let args = ["--cwd", dir.path] + options + ["flow", "run", flowFile.path] + arguments
        let interrupting = interruptWhenLogged != nil
        return await withIsolatedStore {
            let capture = Console.Capture()
            let code = await onThreadOfItsOwn {
                Console.$capture.withValue(capture) {
                    Interrupts.$source.withValue(interrupting ? source : nil) { runCommandLine(args) }
                }
            }
            var run = Run(out: capture.out, err: capture.err, code: code)
            let runs = FlowRunner.runsBaseDir()
            guard let runId = try? FileManager.default.contentsOfDirectory(atPath: runs.path).first else { return run }
            let runDir = runs.appendingPathComponent(runId)
            run.state = try? WireJSON.parse(String(
                contentsOf: runDir.appendingPathComponent("projections/run.json"), encoding: .utf8))
            let golden = AcpGolden(runId: runId, runs: runs.path, flowDir: dir.path, runDir: runDir)
            run.out = golden.normalized(run.out)
            run.err = golden.normalized(run.err)
            run.files = golden.files()
            return run
        }
    }

    /// SIGINT once a FIFO at `path` has been written a line holding `text`. It is read on
    /// until cancelled: an agent logging to it waits for a reader.
    static func fire(_ source: Interrupts.Source, whenLogged text: String, at path: URL) throws -> DispatchSourceRead {
        guard mkfifo(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let fd = open(path.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let seen = Lines()
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0, !seen.all.joined().contains(text) else { return }
            seen.add(String(decoding: buffer[0..<count], as: UTF8.self))
            if seen.all.joined().contains(text) { source.fire("SIGINT") }
        }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        return reader
    }

    /// The events of the run's session called `prefix`, as normalized.
    private func events(_ run: Run, _ prefix: String) -> [WireJSON] {
        let path = run.files.keys.first { $0.hasPrefix("sessions/\(prefix)") && $0.hasSuffix("events.ndjson") }
        return (path.flatMap { run.files[$0]?["content"] } ?? "").split(separator: "\n")
            .compactMap { try? WireJSON.parse(String($0)) }
    }

    // MARK: - A bundle as acpx writes it

    /// A run of isolated ACP nodes — a whole turn of the agent's, content blocks in a
    /// directory the flow picks, the agent's error routed on — writes the bundle acpx
    /// wrote for it, byte for byte once normalized, and reports what acpx did on stderr:
    /// each prompt's token usage.
    @Test(.enabled(if: nodeAvailable && pythonAvailable))
    func theAcpBundleIsWrittenAsAcpxWritesIt() async throws {
        let fixture = try WireJSON.parse(String(
            contentsOf: Self.fixtures.appendingPathComponent("flows/golden-acp-acpx-0.19.3.json"), encoding: .utf8))
        let run = try await flowRun(
            "golden-acp.flow.mjs", options: ["--format", "json"],
            arguments: ["--input-json", #"{"topic":"golden","dir":"sub"}"#])
        #expect(run.code == 0, "\(run.err)")
        #expect(run.out == fixture["stdout"]?.stringValue)
        #expect(run.err == fixture["stderr"]?.stringValue)
        let expected = fixture["files"]?.objectMembers ?? []
        #expect(Set(run.files.keys) == Set(expected.map { String(decoding: $0.key, as: UTF16.self) }))
        for file in expected {
            let path = String(decoding: file.key, as: UTF16.self)
            #expect(run.files[path]?["content"] == file.value["content"]?.stringValue, "\(path)")
            #expect(run.files[path]?["mode"] == file.value["mode"]?.stringValue, "\(path)")
        }
    }

    // MARK: - What the CLI's turn does

    private static let held = """
        export default defineFlow({ name: "held", startAt: "ask", nodes: {
          ask: acp({ profile: "mock", heartbeatMs: 0, session: { isolated: true }, prompt: () => "hold" }) },
          edges: [] });
        """

    /// acpx's flow runner passes the agent neither `--no-terminal` nor a system prompt:
    /// the turn advertises a terminal, and its session has no system prompt.
    @Test(.enabled(if: nodeAvailable && pythonAvailable))
    func aTurnTakesOnlyTheFlagsAcpxsFlowRunnerPassesOn() async throws {
        let run = try await flowRun(
            "flags.flow.mjs", body: Self.held.replacingOccurrences(of: "\"hold\"", with: "\"hi\""),
            options: ["--no-terminal", "--system-prompt", "be brief", "--no-fs"])
        #expect(run.code == 0, "\(run.err)")
        let sent = events(run, "isolated-ask-1").filter { $0["direction"] == .text("outbound") }
        let capabilities = sent.first?["message"]?["params"]?["clientCapabilities"]
        #expect(capabilities?["terminal"] == .bool(true))
        #expect(capabilities?["fs"] == .object([("readTextFile", .bool(false)), ("writeTextFile", .bool(false))]))
        let new = sent.first { $0["message"]?["method"] == .text("session/new") }
        #expect(new?["message"]?["params"]?.hasMember("_meta") == false)
    }

    /// An interrupt while the agent holds its prompt: the prompt is cancelled, and once the
    /// agent answers — within the 2.5 s acpx waits — its agent closed; the run fails
    /// `Interrupted`, the session published with the cancel and its answer.
    @Test(.enabled(if: nodeAvailable && pythonAvailable))
    func anInterruptCancelsTheHeldPrompt() async throws {
        let run = try await flowRun(
            "held.flow.mjs", body: Self.held, agentEnvironment: ["MOCK_HOLD_UNTIL_CANCEL": "1"],
            interruptWhenLogged: "session/prompt")
        #expect(run.code == ExitCodes.interrupted)
        #expect(member(run.state, "error") == .text("Interrupted"))
        #expect(member(run.state, "results", "ask", "outcome") == .text("cancelled"))
        let methods = events(run, "isolated-ask-1").map {
            $0["message"]?["method"]?.stringValue ?? $0["message"]?["result"]?["stopReason"]?.stringValue ?? "?"
        }
        #expect(methods.suffix(3) == ["session/prompt", "session/cancel", "cancelled"])
    }

    /// A turn that needed a permission question nobody could be asked — a write under
    /// `--approve-reads`, non-interactive with `fail` — fails as acpx's client fails it once
    /// the prompt is over: `PERMISSION_PROMPT_UNAVAILABLE`, exit 5, its JSON error the
    /// client's own refusal, which acpx attaches to the failure.
    @Test(.enabled(if: nodeAvailable && pythonAvailable))
    func aTurnThatNeededAnUnaskableQuestionFails() async throws {
        let run = try await flowRun(
            "write.flow.mjs", body: Self.held.replacingOccurrences(of: "\"hold\"", with: "\"write\""),
            options: ["--approve-reads", "--non-interactive-permissions", "fail", "--format", "json"],
            agentScript: "write-agent.py")
        let unavailable = "Permission prompt unavailable in non-interactive mode"
        #expect(run.code == 5)
        #expect(member(run.state, "results", "ask", "error") == .text(unavailable))
        let line = try WireJSON.parse(run.out.trimmingCharacters(in: .newlines))
        #expect(line["error"]?["code"] == .number(-32603) && line["error"]?["message"] == .text("Internal error"))
        #expect(line["error"]?["data"]?["acpxCode"] == .text("PERMISSION_PROMPT_UNAVAILABLE"))
        #expect(line["error"]?["data"]?["details"] == .text(unavailable))
    }

    /// A node naming its agent under `--agent`, which acpx refuses to combine, fails with
    /// acpx's message — the step's and the run's — and its usage exit code.
    @Test(.enabled(if: nodeAvailable && pythonAvailable))
    func aNodesProfileIsRefusedBesideAnAgentOverride() async throws {
        let run = try await flowRun("override.flow.mjs", body: Self.held, options: ["--agent", "python3 -V"])
        #expect(run.code == ExitCodes.usage)
        let refusal = "Do not combine positional agent with --agent override"
        #expect(run.err == refusal + "\n")
        #expect(member(run.state, "results", "ask", "error") == .text(refusal))
    }

    private func member(_ value: WireJSON?, _ path: String...) -> WireJSON? {
        path.reduce(value) { $0?[$1] }
    }
}

/// A run's bundle normalized as `record-golden-acp.py` normalizes acpx's: the run's id and
/// its suffix, the runs and flow directories, each session's bundle id (which hashes its
/// directory), times, durations and UUIDs replaced; artifacts named, and referred to, by
/// what they hold once normalized; and in each session's events, the ways SwiftACP's own
/// messages differ from acpx's on the wire left out — their keys sorted (#64), request ids
/// counted from the first, and `clientInfo`.
struct AcpGolden {
    let runId: String
    let runs: String
    let flowDir: String
    let runDir: URL

    private var bundleIds: [String] {
        let sessions = runDir.appendingPathComponent("sessions")
        return ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).sorted()
    }

    func normalized(_ original: String) -> String {
        var text = original
        for bundleId in bundleIds {
            text = text.replacingOccurrences(of: bundleId, with: String(bundleId.dropLast(8)) + "<BUNDLE>")
        }
        text = text.replacingOccurrences(of: runId, with: "<RUNID>")
            .replacingOccurrences(of: String(runId.suffix(8)), with: "<RUNSFX>")
            .replacingOccurrences(of: runs, with: "<RUNS>").replacingOccurrences(of: flowDir, with: "<FLOWDIR>")
            .replacingOccurrences(
                of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"#, with: "<TIME>", options: .regularExpression)
            .replacingOccurrences(
                of: #""durationMs":( ?)\d+"#, with: #""durationMs":$1<MS>"#, options: .regularExpression)
        var seen: [String: String] = [:]
        return Self.replacing(#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, in: text) { match in
            if let known = seen[match[0]] { return known }
            let named = "<UUID\(seen.count + 1)>"
            seen[match[0]] = named
            return named
        }
    }

    func files() -> [String: [String: String]] {
        var texts: [String: (mode: String, text: String)] = [:]
        let enumerator = FileManager.default.enumerator(atPath: runDir.path)
        while let relative = enumerator?.nextObject() as? String {
            let url = runDir.appendingPathComponent(relative)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let mode = attributes[.posixPermissions] as? Int,
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            texts[relative] = ("0o" + String(mode & 0o777, radix: 8), normalized(content))
        }
        var canon: [String: String] = [:]
        for (relative, file) in texts where relative.hasPrefix("artifacts/sha256-") {
            let sha = String(relative.dropFirst("artifacts/sha256-".count).prefix(64))
            canon[sha] = String(SHA256.hash(data: Data(file.text.utf8)).map { String(format: "%02x", $0) }.joined()
                .prefix(16))
        }
        let reference = #"\{\s*"path":\s*"artifacts/sha256-([0-9a-f]{64})(\.[a-z]+)",\s*"mediaType":\s*"([^"]*)","#
            + #"\s*"bytes":\s*\d+,\s*"sha256":\s*"[0-9a-f]{64}"\s*\}"#
        var files: [String: [String: String]] = [:]
        for (original, file) in texts {
            var text = Self.replacing(reference, in: file.text) { "<ARTIFACT \(canon[$0[1]] ?? "?")\($0[2]) \($0[3])>" }
            if original.hasSuffix("events.ndjson") { text = Self.knownWire(text) }
            var relative = original
            for (sha, short) in canon { relative = relative.replacingOccurrences(of: "sha256-" + sha, with: short) }
            for bundleId in bundleIds {
                relative = relative.replacingOccurrences(of: bundleId, with: String(bundleId.dropLast(8)) + "<BUNDLE>")
            }
            files[relative] = ["mode": file.mode, "content": text]
        }
        return files
    }

    /// Each match of `pattern` in `text` replaced with what `replacement` makes of its groups.
    private static func replacing(_ pattern: String, in text: String, _ replacement: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += replacement(groups)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    /// The session's events with SwiftACP's own wire differences left out.
    private static func knownWire(_ text: String) -> String {
        var events = text.split(separator: "\n").compactMap { WireJSON(parsing: Data($0.utf8)) }
        var base: Double?
        for index in events.indices {
            guard events[index]["direction"] == .text("outbound"), let sent = events[index]["message"],
                  case .object = sent
            else { continue }
            var message = sortedKeys(sent)
            if let params = message["params"], params.hasMember("clientInfo") {
                message = message.replacing("params", with: params.replacing("clientInfo", with: .text("<CLIENT>")))
            }
            events[index] = events[index].replacing("message", with: message)
            if base == nil, message.hasMember("method"), case .number(let id)? = message["id"], id == id.rounded() {
                base = id
            }
        }
        for index in events.indices {
            guard let message = events[index]["message"], case .object = message, let base,
                  message.hasMember("method") == (events[index]["direction"] == .text("outbound")),
                  case .number(let id)? = message["id"], id == id.rounded()
            else { continue }
            events[index] = events[index].replacing(
                "message", with: message.replacing("id", with: .text("<ID+\(Int(id - base))>")))
        }
        return events.map { $0.stringified + "\n" }.joined()
    }

    private static func sortedKeys(_ value: WireJSON) -> WireJSON {
        switch value {
        case .object(let members):
            return .object(members.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map {
                WireJSON.Member(key: $0.key, value: sortedKeys($0.value))
            })
        case .array(let items):
            return .array(items.map(sortedKeys))
        default:
            return value
        }
    }
}
