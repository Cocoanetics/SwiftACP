@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// What an agent can reach through `fs/read_text_file` and `fs/write_text_file`, and
/// what it hears back when it cannot (issue #34).
///
/// acpx checks twice — lexically before anything else, then on disk through its
/// fs-safe root — and every refusal reaches the agent as the ACP SDK reports a thrown
/// error: `-32603 "Internal error"` with the reason in `data.details`. The wording and
/// shapes asserted here were captured from npm acpx 0.19.1 driving the same requests.
struct FileSystemContainmentTests {
    // MARK: Fixtures

    /// A workspace with `inside.txt`, a `link-out` symlink to a file outside it, and a
    /// sibling `outside.txt`. Returns (root, outsideFile).
    private func makeWorkspace() throws -> (root: String, outside: String) {
        let created = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // Canonicalise *after* creating it: only an existing path can be resolved, and
        // the platform hands out aliases that containment will resolve away — macOS's
        // /var → /private/var, and Windows' 8.3 short names (RUNNER~1 → runneradmin).
        let root = created.resolvingSymlinksInPath()
        let base = root.deletingLastPathComponent()
        try "inside".write(
            to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        let outside = base.appendingPathComponent("outside.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link-out"), withDestinationURL: outside)
        return (root.path, outside.path)
    }

    /// Join with the platform's own separator: a resolved path on Windows comes back
    /// with backslashes, so `root + "/name"` would never match it.
    private func path(_ base: String, _ components: String...) -> String {
        components.reduce(URL(fileURLWithPath: base)) { $0.appendingPathComponent($1) }.path
    }

    /// The `data.details` a refusal carries, or `nil` if it is not a refusal.
    private func details(_ error: Error?) -> String? {
        guard let error = error as? JSONRPCErrorBody, error.code == -32603,
            error.message == "Internal error",
            case .object(let data)? = error.data, case .string(let details)? = data["details"]
        else { return nil }
        return details
    }

    // MARK: Stage 1 — lexical

    @Test func aFileInsideTheWorkspacePasses() throws {
        let (root, _) = try makeWorkspace()
        let named = try FileSystemContainment.lexicallyContained(path(root, "inside.txt"), under: root)
        #expect(named == path(root, "inside.txt"))
    }

    #if !os(Windows)
    @Test func aRelativePathIsRefusedBeforeAnythingElse() throws {
        let (root, _) = try makeWorkspace()
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.lexicallyContained("inside.txt", under: root)
        }
        #expect(details(error) == "Path must be absolute: inside.txt")
    }

    /// The refusal names the path with `..` folded — the path acpx itself reports.
    @Test func aPathOutsideTheWorkspaceIsRefusedWithItsNormalizedForm() throws {
        let (root, outside) = try makeWorkspace()
        let direct = #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.lexicallyContained(outside, under: root)
        }
        #expect(details(direct) == "Path is outside allowed cwd subtree: \(outside)")

        let climbing = #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.lexicallyContained(root + "/../outside.txt", under: root)
        }
        #expect(details(climbing) == "Path is outside allowed cwd subtree: \(outside)")
    }

    /// Purely textual: no disk access, and `/private` is not dropped the way
    /// Foundation's `standardizingPath` drops it.
    @Test func lexicalNormalizationFoldsWithoutTouchingTheDisk() {
        #expect(FileSystemContainment.lexicallyNormalized("/private/tmp/a/./b/../c//d/")
            == "/private/tmp/a/c/d")
        #expect(FileSystemContainment.lexicallyNormalized("/../../x") == "/x")
        #expect(FileSystemContainment.lexicallyNormalized("/") == "/")
    }

    /// The root itself counts as inside, as in fs-safe's `isPathInside`; a sibling that
    /// merely shares a prefix does not.
    @Test func containmentIsByComponentNotByPrefix() throws {
        let (root, _) = try makeWorkspace()
        #expect(throws: Never.self) { try FileSystemContainment.lexicallyContained(root, under: root) }
        #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.lexicallyContained(root + "-sibling/x", under: root)
        }
    }
    #endif

    // MARK: Stage 2 — on disk

    @Test func aSymlinkLeavingTheWorkspaceIsRefused() throws {
        let (root, _) = try makeWorkspace()
        // The link itself lives inside the root; its target does not.
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.resolveWithinRealRoot(path(root, "link-out"), under: root)
        }
        #expect(details(error) == "file is outside workspace root")
    }

    @Test func aSymlinkedWorkspaceStillWorks() throws {
        let (root, _) = try makeWorkspace()
        let alias = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: root))

        // The session cwd is the alias; a file named through it must still resolve.
        let named = path(alias.path, "inside.txt")
        _ = try FileSystemContainment.lexicallyContained(named, under: alias.path)
        let resolved = try FileSystemContainment.resolveWithinRealRoot(named, under: alias.path)
        #expect(URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: path(root, "inside.txt")).resolvingSymlinksInPath().path)
    }

    @Test func aWriteMayNameAFileThatDoesNotExistYet() throws {
        let (root, outside) = try makeWorkspace()
        let fresh = try FileSystemContainment.resolveWithinRealRoot(
            path(root, "nested", "new.txt"), under: root)
        #expect(fresh.hasSuffix("nested/new.txt") || fresh.hasSuffix("nested\\new.txt"))

        // …but not one that would land outside.
        #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.resolveWithinRealRoot(
                (outside as NSString).deletingLastPathComponent + "/new.txt", under: root)
        }
    }

    #if !os(Windows)
    /// A missing file under a workspace reached through `/tmp` → `/private/tmp`. Found
    /// while porting: comparing through `URL.standardizedFileURL` dropped `/private`
    /// from the existing root but not from the not-yet-existing file, so every new file
    /// looked outside the workspace.
    @Test func aMissingFileUnderAnAliasedRootIsStillInside() throws {
        let workspace = "/tmp/fs-alias-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workspace) }
        let privateForm = "/private" + workspace
        guard FileManager.default.fileExists(atPath: privateForm) else { return }  // not macOS

        let named = try FileSystemContainment.lexicallyContained(
            privateForm + "/fresh.txt", under: privateForm)
        #expect(named == privateForm + "/fresh.txt")
        _ = try FileSystemContainment.resolveWithinRealRoot(named, under: privateForm)
    }

    /// acpx 0.18.0: `..` is applied to what a symlink points at, not folded into the
    /// text first. `link/../file` with `link -> /elsewhere` is `/file` — outside —
    /// not the lexical sibling `file`.
    @Test func dotDotAfterAnEscapingSymlinkIsResolvedPhysically() throws {
        let (root, _) = try makeWorkspace()
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elsewhere-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/away", withDestinationPath: outsideDir)

        let named = root + "/away/../inside.txt"
        // Lexically this is the workspace's own inside.txt…
        #expect(try FileSystemContainment.lexicallyContained(named, under: root) == root + "/inside.txt")
        // …but on disk it is not.
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try FileSystemContainment.resolveWithinRealRoot(named, under: root)
        }
        #expect(details(error) == "file is outside workspace root")
    }
    #endif

    // MARK: Wire shapes

    @Test func aRefusalIsAnInternalErrorWithDetails() {
        let error = FileSystemContainment.refused("not a file")
        #expect(error.code == -32603)
        #expect(error.message == "Internal error")
        #expect(error.data == .object(["details": .string("not a file")]))
    }

    /// acpx's `RequestError.resourceNotFound(pathToFileURL(path).href)`: the file URI in
    /// both the message and `data.uri`, percent-encoded.
    @Test func resourceNotFoundCarriesTheFileURI() {
        let error = FileSystemContainment.resourceNotFound("/work/no such file.txt")
        #expect(error.code == -32002)
        #expect(error.message == "Resource not found: file:///work/no%20such%20file.txt")
        #expect(error.data == .object(["uri": .string("file:///work/no%20such%20file.txt")]))
    }

    // MARK: What the open decides

    /// Existence and file type are settled on the descriptor, not on the path: between
    /// a path check and an open, the object can be replaced.
    @Test func aMissingFileReadsAsResourceNotFound() throws {
        let (root, _) = try makeWorkspace()
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try LocalFileSystem.read(ReadTextFileRequest(sessionId: "s", path: root + "/absent.txt"))
        }
        #expect(error?.code == FileSystemContainment.resourceNotFoundCode)
    }

    @Test func aSymlinkSwappedInAfterContainmentFailsTheOpen() throws {
        let (root, outside) = try makeWorkspace()
        // `link-out` is inside the root but points out of it. Containment resolves paths
        // before the handler sees them, so this only arises when the object changes
        // after the check — the no-follow open is what refuses it.
        #expect(throws: (any Error).self) {
            try LocalFileSystem.read(ReadTextFileRequest(sessionId: "s", path: root + "/link-out"))
        }
        #expect(FileManager.default.contents(atPath: outside) != nil)
    }

    // `mkfifo` and hard links are POSIX-only; Windows has no equivalent to exercise here.
    #if !os(Windows)
    @Test func aSpecialFileIsNotReadable() throws {
        let (root, _) = try makeWorkspace()
        let fifo = root + "/pipe"
        #expect(mkfifo(fifo, 0o600) == 0)
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try LocalFileSystem.read(ReadTextFileRequest(sessionId: "s", path: fifo))
        }
        #expect(details(error) == "not a file")
    }

    @Test func aDirectoryIsNotReadable() throws {
        let (root, _) = try makeWorkspace()
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try LocalFileSystem.read(ReadTextFileRequest(sessionId: "s", path: root))
        }
        #expect(details(error) == "not a file")
    }

    /// Opening a fifo for writing blocks until a reader turns up. Before `O_NONBLOCK`
    /// this hung the client forever; it must now refuse at once.
    @Test func writingToAFifoIsRefusedInsteadOfHanging() throws {
        let (root, _) = try makeWorkspace()
        let fifo = root + "/pipe"
        #expect(mkfifo(fifo, 0o600) == 0)
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try LocalFileSystem.write(WriteTextFileRequest(sessionId: "s", path: fifo, content: "x"))
        }
        #expect(details(error) == "path is not a regular file under root")
    }

    @Test func writingToADirectoryIsRefused() throws {
        let (root, _) = try makeWorkspace()
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try LocalFileSystem.write(WriteTextFileRequest(sessionId: "s", path: root, content: "x"))
        }
        #expect(details(error) == "not a file")
    }

    /// A hard link is a regular file, so `O_NOFOLLOW` does not stop it — and writing
    /// through one changes the other link's file, which may be outside the workspace.
    /// fs-safe refuses; the outside file must be untouched.
    @Test func writingThroughAHardLinkIsRefusedAndLeavesTheOtherLinkAlone() throws {
        let (root, outside) = try makeWorkspace()
        let linked = root + "/linked.txt"
        #expect(link(outside, linked) == 0)
        let error = #expect(throws: JSONRPCErrorBody.self) {
            try LocalFileSystem.write(
                WriteTextFileRequest(sessionId: "s", path: linked, content: "overwritten"))
        }
        #expect(details(error) == "path alias escape blocked")
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == "secret")
    }

    /// …while *reading* through one is allowed, as upstream (`hardlinks: "allow"`).
    @Test func readingThroughAHardLinkIsAllowed() throws {
        let (root, outside) = try makeWorkspace()
        #expect(link(outside, root + "/linked.txt") == 0)
        let read = try LocalFileSystem.read(ReadTextFileRequest(sessionId: "s", path: root + "/linked.txt"))
        #expect(read.content == "secret")
    }
    #endif

    @Test func aWriteCreatesMissingParentsAndTruncates() throws {
        let (root, _) = try makeWorkspace()
        let nested = path(root, "a", "b", "c.txt")
        _ = try LocalFileSystem.write(WriteTextFileRequest(sessionId: "s", path: nested, content: "first, longer"))
        _ = try LocalFileSystem.write(WriteTextFileRequest(sessionId: "s", path: nested, content: "short"))
        #expect(try String(contentsOfFile: nested, encoding: .utf8) == "short")
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
    }

    /// A symlink *inside* the workspace pointing at a file inside it keeps working:
    /// the handler is handed the resolved path, so the no-follow open sees the real
    /// file rather than the link. acpx calls this preserving contained aliases.
    @Test func aContainedAliasStillReadsEndToEnd() async throws {
        let (root, _) = try makeWorkspace()
        try FileManager.default.createSymbolicLink(
            atPath: root + "/alias.txt", withDestinationPath: root + "/inside.txt")

        let text = try await runRead(ReadProbeAgent(path: root + "/alias.txt"), cwd: root)
        #expect(text == "read:inside")
    }

    @Test func unrestrictedAccessRestoresTheOldBehaviour() async throws {
        let (root, outside) = try makeWorkspace()
        let text = try await runRead(
            ReadProbeAgent(path: outside), cwd: root, access: .unrestricted)
        #expect(text == "read:secret")
    }
}
