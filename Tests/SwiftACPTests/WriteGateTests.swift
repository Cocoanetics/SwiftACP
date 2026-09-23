@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// Whether an agent may write a file — acpx's `isWriteApproved` (issue #34). The
/// agent never sends a permission request for `fs/write_text_file`, so the client asks
/// on its own; before this, `--deny-all` did not deny file writes at all. Outcomes and
/// wire shapes were captured from npm acpx 0.19.1 driving the same requests.
@Suite(.timeLimit(.minutes(1)))
struct WriteGateTests {
    private let write = WriteTextFileRequest(sessionId: "s", path: "/w/a.txt", content: "hello\n")

    /// A prompt that has no terminal: the default confirmation must never block.
    private let noTerminal = TerminalPermissionPrompt(
        input: Pipe().fileHandleForReading, output: Pipe().fileHandleForWriting,
        isTerminal: { false })

    private func approval(
        _ policy: PermissionPolicy, _ nonInteractive: NonInteractivePermissionPolicy = .deny,
        confirm: WriteApproval.Confirmation? = nil
    ) -> WriteApproval {
        WriteApproval(policy: policy, nonInteractive: nonInteractive, confirm: confirm, prompt: noTerminal)
    }

    // MARK: The decision

    @Test func approveAllWritesWithoutAsking() async throws {
        try await approval(.approveAll, confirm: { _, _ in Issue.record("asked"); return false })
            .authorize(write)
    }

    @Test func denyAllRefusesWithoutAsking() async {
        await #expect(throws: FileSystemPermissionError.denied) {
            try await approval(.denyAll, confirm: { _, _ in Issue.record("asked"); return true })
                .authorize(write)
        }
    }

    @Test func approveReadsAsksAndHonoursTheAnswer() async throws {
        let asked = Recorder<(String, String)>()
        try await approval(.approveReads, confirm: { path, preview in
            asked.append((path, preview))
            return true
        }).authorize(write)
        #expect(asked.values.map(\.0) == ["/w/a.txt"])
        #expect(asked.values.map(\.1) == ["hello\n"])

        await #expect(throws: FileSystemPermissionError.denied) {
            try await approval(.approveReads, confirm: { _, _ in false }).authorize(write)
        }
    }

    /// `.custom` answers tool-call requests; a write carries none, so it asks.
    @Test func aCustomPolicyAsksToo() async throws {
        await #expect(throws: FileSystemPermissionError.denied) {
            try await approval(.custom({ _ in .cancelled }), confirm: { _, _ in false }).authorize(write)
        }
    }

    /// With no terminal the default prompt answers no — or, under `fail`, the write
    /// is refused as unanswerable.
    @Test func headlessTheDefaultPromptDeniesOrFails() async {
        await #expect(throws: FileSystemPermissionError.denied) {
            try await approval(.approveReads, .deny).authorize(write)
        }
        await #expect(throws: FileSystemPermissionError.promptUnavailable) {
            try await approval(.approveReads, .fail).authorize(write)
        }
    }

    /// `fail` only guards the *default* prompt: an embedder's own confirmation is
    /// trusted to answer without a terminal, as upstream's `usesDefaultConfirmWrite`.
    @Test func failDoesNotOverrideAnEmbeddersConfirmation() async throws {
        try await approval(.approveReads, .fail, confirm: { _, _ in true }).authorize(write)
    }

    @Test func refusalsCarryAcpxsWording() {
        #expect(FileSystemPermissionError.denied.description == "Permission denied for fs/write_text_file")
        #expect(FileSystemPermissionError.promptUnavailable.description
            == "Permission prompt unavailable in non-interactive mode")
    }

    // MARK: The preview

    @Test func thePreviewKeepsSixteenLinesAndCountsTheRest() {
        let content = (1 ... 20).map { "line \($0)" }.joined(separator: "\r\n")
        let preview = WriteApproval.preview(of: content)
        #expect(preview.hasPrefix("line 1\nline 2\n"))
        #expect(preview.hasSuffix("line 16\n... (4 more lines)"))
    }

    @Test func thePreviewIsCappedAtTwelveHundredCharacters() {
        let preview = WriteApproval.preview(of: String(repeating: "x", count: 5_000))
        #expect(preview.utf16.count == 1_200)
        #expect(preview.hasSuffix("..."))
    }

    @Test func aShortWriteIsPreviewedVerbatim() {
        #expect(WriteApproval.preview(of: "hello\nworld\n") == "hello\nworld\n")
    }

    // MARK: End to end, through the client

    /// An agent that asks for permission for a tool first (optionally), then asks the
    /// client to write `path`, and reports the outcome — including the error shape.
    struct WriteProbeAgent: ACPAgentHandler {
        var path: String
        var askToolPermissionFirst = false

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "write-probe", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "write-session")
        }

        func prompt(
            _ request: PromptRequest, session: ACPServerSession
        ) async throws -> PromptResponse {
            if askToolPermissionFirst {
                _ = try await session.requestPermission(
                    toolCall: ToolCallUpdate(toolCallId: "t1", title: "Read file", kind: .read),
                    options: [
                        PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce),
                        PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce)
                    ])
            }
            do {
                try await session.writeTextFile(path: path, content: "written")
                await session.sendText("ok")
            } catch let error as JSONRPCErrorBody {
                var details = ""
                if case .object(let data)? = error.data, case .string(let text)? = data["details"] {
                    details = text
                }
                await session.sendText("error|\(error.code)|\(error.message)|\(details)")
            }
            return PromptResponse(stopReason: .endTurn)
        }
    }

    struct Run {
        var reply: String
        var stats: PermissionStats
        var received: [String]
        var failures: [String]
    }

    private func run(
        _ agent: WriteProbeAgent, cwd: String, handlers: ACPClientHandlers
    ) async throws -> Run {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: agent, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport, handlers: handlers)
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: cwd))

        let (subscriptionId, stream) = await client.makeEventSubscription()
        let consumer = Task { () -> Run in
            var run = Run(reply: "", stats: PermissionStats(), received: [], failures: [])
            for await event in stream {
                switch event {
                case .update(let note):
                    if case .agentMessageChunk(let block) = note.update, let chunk = block.text {
                        run.reply += chunk
                    }
                case .inboundRequest(let request):
                    if let failure = request.failure { run.failures.append(failure) } else {
                        run.received.append(request.method)
                    }
                case .clientOperation:
                    break
                }
            }
            return run
        }
        _ = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        await client.endSubscription(subscriptionId)
        var run = await consumer.value
        run.stats = await client.permissionStats(for: session.sessionId)
        await client.close()
        serverTask.cancel()
        return run
    }

    private func workspace() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    private func handlers(
        _ policy: PermissionPolicy, _ nonInteractive: NonInteractivePermissionPolicy = .deny,
        confirm: WriteApproval.Confirmation? = nil
    ) -> ACPClientHandlers {
        var handlers = ACPClientHandlers.standard(permission: policy)
        let gate = WriteApproval(
            policy: policy, nonInteractive: nonInteractive, confirm: confirm, prompt: noTerminal)
        handlers.authorizeWrite = { try await gate.authorize($0) }
        return handlers
    }

    @Test func anApprovedWriteLandsAndCountsForNothing() async throws {
        let root = try workspace()
        let run = try await run(
            WriteProbeAgent(path: root + "/a.txt"), cwd: root, handlers: handlers(.approveAll))
        #expect(run.reply == "ok")
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "written")
        // Upstream records delegated operations only when they fail.
        #expect(run.stats == PermissionStats())
        #expect(run.received == ["fs/write_text_file"])
    }

    /// `--deny-all` now means what it says for writes, and the agent hears it in
    /// acpx's shape: `Internal error`, the reason in `data.details`.
    @Test func denyAllRefusesTheWriteInAcpxsShape() async throws {
        let root = try workspace()
        let run = try await run(
            WriteProbeAgent(path: root + "/a.txt"), cwd: root, handlers: handlers(.denyAll))
        #expect(run.reply == "error|-32603|Internal error|Permission denied for fs/write_text_file")
        #expect(!FileManager.default.fileExists(atPath: root + "/a.txt"))
        #expect(run.stats.denied == 1)
        #expect(run.stats.deniedEverything)
        #expect(run.received == ["fs/write_text_file"])
        #expect(run.failures == ["Permission denied for fs/write_text_file"])
    }

    @Test func anUnanswerablePromptUnderFailIsCountedAsSuch() async throws {
        let root = try workspace()
        let run = try await run(
            WriteProbeAgent(path: root + "/a.txt"), cwd: root, handlers: handlers(.approveReads, .fail))
        #expect(run.reply.hasSuffix("|Permission prompt unavailable in non-interactive mode"))
        #expect(run.stats.cancelled == 1)
        #expect(run.stats.promptUnavailable)
    }

    /// One approved tool call is enough to keep a refused write from making the whole
    /// turn a permission failure — the exit-5 rule counts approvals across both.
    @Test func anApprovedToolCallOutweighsARefusedWrite() async throws {
        let root = try workspace()
        let run = try await run(
            WriteProbeAgent(path: root + "/a.txt", askToolPermissionFirst: true), cwd: root,
            handlers: handlers(.approveReads, confirm: { _, _ in false }))
        #expect(run.stats.approved == 1)
        #expect(run.stats.denied == 1)
        #expect(run.stats.deniedEverything == false)
    }

    /// The agent's requests travel the same stream as its updates, so a consumer sees
    /// them in wire order: text the agent streamed before asking to write comes out
    /// before the write, never after it.
    @Test func inboundRequestsArriveInOrderWithUpdates() async throws {
        struct ChattyWriter: ACPAgentHandler {
            var path: String
            func initialize(_ request: InitializeRequest) async -> InitializeResponse {
                InitializeResponse(agentInfo: Implementation(name: "chatty", version: "1.0"))
            }
            func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
                NewSessionResponse(sessionId: "chatty-session")
            }
            func prompt(
                _ request: PromptRequest, session: ACPServerSession
            ) async throws -> PromptResponse {
                await session.sendText("before")
                try? await session.writeTextFile(path: path, content: "x")
                await session.sendText("after")
                return PromptResponse(stopReason: .endTurn)
            }
        }
        let root = try workspace()
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: ChattyWriter(path: root + "/a.txt"), transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(transport: clientTransport, handlers: handlers(.denyAll))
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: root))

        let (subscriptionId, stream) = await client.makeEventSubscription()
        let consumer = Task { () -> [String] in
            var seen: [String] = []
            for await event in stream {
                switch event {
                case .update(let note):
                    if case .agentMessageChunk(let block) = note.update, let text = block.text {
                        seen.append("text:\(text)")
                    }
                case .inboundRequest(let request):
                    seen.append(request.failure.map { "refused:\($0)" } ?? "request:\(request.method)")
                case .clientOperation:
                    break
                }
            }
            return seen
        }
        _ = try await client.prompt(PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        await client.endSubscription(subscriptionId)
        #expect(await consumer.value == [
            "text:before",
            "request:fs/write_text_file",
            "refused:Permission denied for fs/write_text_file",
            "text:after"
        ])
        await client.close()
        serverTask.cancel()
    }

    /// acpx's order: a path plainly outside the workspace is refused *without asking*.
    @Test func aPathOutsideTheWorkspaceIsRefusedBeforeAnyoneIsAsked() async throws {
        let root = try workspace()
        let asked = Recorder<String>()
        let outside = (root as NSString).deletingLastPathComponent + "/elsewhere.txt"
        let run = try await run(
            WriteProbeAgent(path: outside), cwd: root,
            handlers: handlers(.approveReads, confirm: { path, _ in asked.append(path); return true }))
        #expect(run.reply == "error|-32603|Internal error|Path is outside allowed cwd subtree: \(outside)")
        #expect(asked.values.isEmpty)
        // A path refusal is not a permission decision.
        #expect(run.stats == PermissionStats())
    }

    /// …while one that only escapes on disk — through a symlink — is asked about
    /// first, and refused after the answer, as upstream.
    #if !os(Windows)
    @Test func aPathThatEscapesOnDiskIsAskedAboutFirst() async throws {
        let root = try workspace()
        let away = try workspace()
        try FileManager.default.createSymbolicLink(atPath: root + "/away", withDestinationPath: away)
        let asked = Recorder<String>()
        let run = try await run(
            WriteProbeAgent(path: root + "/away/a.txt"), cwd: root,
            handlers: handlers(.approveReads, confirm: { path, _ in asked.append(path); return true }))
        #expect(asked.values == [root + "/away/a.txt"])
        #expect(run.reply == "error|-32603|Internal error|file is outside workspace root")
        #expect(!FileManager.default.fileExists(atPath: away + "/a.txt"))
    }
    #endif
}

/// A thread-safe append-only log for callbacks that run off the test's task.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}
