@testable import SwiftACP
import Foundation
import Testing

/// What an agent can reach through `fs/read_text_file` and `fs/write_text_file`. The
/// client confines every path to the session's own working directory, decided on the
/// resolved path so a symlinked workspace keeps working and a symlink out of it does
/// not (acpx's fs-safe roots, 0.16.0 / 0.18.0 — issue #34).
struct FileSystemContainmentTests {
    // MARK: Fixtures

    /// A workspace with `inside.txt`, a `link-out` symlink to a file outside it, and a
    /// sibling `outside.txt`. Returns (root, outsideFile).
    private func makeWorkspace() throws -> (root: String, outside: String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "inside".write(
            to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        let outside = base.appendingPathComponent("outside.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link-out"), withDestinationURL: outside)
        return (root.path, outside.path)
    }

    // MARK: Path rules

    @Test func aFileInsideTheWorkspaceResolves() throws {
        let (root, _) = try makeWorkspace()
        let resolved = try FileSystemContainment.resolve(
            path: root + "/inside.txt", under: root, for: .read)
        #expect(resolved == root + "/inside.txt")
    }

    @Test func aPathOutsideTheWorkspaceIsRefused() throws {
        let (root, outside) = try makeWorkspace()
        #expect(throws: (any Error).self) {
            try FileSystemContainment.resolve(path: outside, under: root, for: .read)
        }
        // …including one that only leaves lexically.
        #expect(throws: (any Error).self) {
            try FileSystemContainment.resolve(
                path: root + "/../outside.txt", under: root, for: .read)
        }
    }

    @Test func aSymlinkLeavingTheWorkspaceIsRefused() throws {
        let (root, _) = try makeWorkspace()
        // The link itself lives inside the root; its target does not.
        #expect(throws: (any Error).self) {
            try FileSystemContainment.resolve(path: root + "/link-out", under: root, for: .read)
        }
    }

    @Test func aSymlinkedWorkspaceStillWorks() throws {
        let (root, _) = try makeWorkspace()
        let alias = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: root))

        // The session cwd is the alias; a file named through it must still resolve.
        let resolved = try FileSystemContainment.resolve(
            path: alias.path + "/inside.txt", under: alias.path, for: .read)
        #expect(resolved == root + "/inside.txt")
    }

    @Test func aWriteMayNameAFileThatDoesNotExistYet() throws {
        let (root, outside) = try makeWorkspace()
        let fresh = try FileSystemContainment.resolve(
            path: root + "/nested/new.txt", under: root, for: .write)
        #expect(fresh == root + "/nested/new.txt")

        // …but not one that would land outside.
        #expect(throws: (any Error).self) {
            try FileSystemContainment.resolve(
                path: (outside as NSString).deletingLastPathComponent + "/new.txt",
                under: root, for: .write)
        }
    }

    @Test func aMissingFileReadsAsResourceNotFound() throws {
        let (root, _) = try makeWorkspace()
        do {
            _ = try FileSystemContainment.resolve(
                path: root + "/absent.txt", under: root, for: .read)
            Issue.record("expected a resource-not-found error")
        } catch let error as JSONRPCErrorBody {
            #expect(error.code == FileSystemContainment.resourceNotFoundCode)
        }
    }

    @Test func aSpecialFileIsNotReadable() throws {
        let (root, _) = try makeWorkspace()
        let fifo = root + "/pipe"
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(throws: (any Error).self) {
            try FileSystemContainment.resolve(path: fifo, under: root, for: .read)
        }
    }

    // MARK: End to end, through the client

    /// An agent that asks the client to read a path, and reports what it got back.
    struct ReadProbeAgent: ACPAgentHandler {
        var path: String
        var sessionId: String = "fs-session"

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "fs-probe", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: sessionId)
        }

        func prompt(
            _ request: PromptRequest, session: ACPServerSession
        ) async throws -> PromptResponse {
            do {
                await session.sendText("read:" + (try await session.readTextFile(path: path)))
            } catch {
                await session.sendText("error:\(error.localizedDescription)")
            }
            return PromptResponse(stopReason: .endTurn)
        }
    }

    private func runRead(
        _ agent: ReadProbeAgent, cwd: String, access: FileSystemAccessScope = .sessionRoot
    ) async throws -> String {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(handler: agent, transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(
            transport: clientTransport, handlers: .standard(permission: .approveAll))
        await client.setFileSystemAccess(access)
        await client.start()
        _ = try await client.initialize(capabilities: .headlessController, clientInfo: .acpx)
        let session = try await client.newSession(NewSessionRequest(cwd: cwd))

        let (subscriptionId, stream) = await client.makeEventSubscription()
        let consumer = Task { () -> String in
            var text = ""
            for await event in stream {
                if case .update(let note) = event, case .agentMessageChunk(let block) = note.update,
                    let chunk = block.text {
                    text += chunk
                }
            }
            return text
        }
        _ = try await client.prompt(
            PromptRequest(sessionId: session.sessionId, prompt: [.text("go")]))
        await client.endSubscription(subscriptionId)
        let text = await consumer.value
        await client.close()
        serverTask.cancel()
        return text
    }

    @Test func theClientRefusesAReadOutsideTheSessionRoot() async throws {
        let (root, outside) = try makeWorkspace()

        let allowed = try await runRead(ReadProbeAgent(path: root + "/inside.txt"), cwd: root)
        #expect(allowed == "read:inside")

        let refused = try await runRead(ReadProbeAgent(path: outside), cwd: root)
        #expect(refused.hasPrefix("error:"))
        #expect(refused.contains("outside the session's working directory"))
    }

    @Test func unrestrictedAccessRestoresTheOldBehaviour() async throws {
        let (root, outside) = try makeWorkspace()
        let text = try await runRead(
            ReadProbeAgent(path: outside), cwd: root, access: .unrestricted)
        #expect(text == "read:secret")
    }
}
