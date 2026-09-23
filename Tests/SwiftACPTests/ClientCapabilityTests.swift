@testable import SwiftACP
import Foundation
import Testing

/// A method the client did not advertise is not served. acpx registers its `fs/*`
/// handlers only when the matching capability is on, so an agent that calls one anyway
/// gets method-not-found — `--no-fs` has to mean something against a direct request,
/// not just in the handshake (acpx 0.13.0, enforced in 0.17.1 — issue #28).
struct ClientCapabilityTests {
    /// Asks the client to read a file and reports what came back.
    struct ReadProbeAgent: ACPAgentHandler {
        var path: String

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "cap-probe", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "cap-session")
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

    private func runRead(capabilities: ClientCapabilities) async throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "contents".write(to: file, atomically: true, encoding: .utf8)

        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        let server = ACPAgentServer(
            handler: ReadProbeAgent(path: file.path), transport: serverTransport)
        let serverTask = Task { try await server.run() }
        let client = ACPAgentConnection(
            transport: clientTransport, handlers: .standard(permission: .approveAll))
        await client.start()
        _ = try await client.initialize(capabilities: capabilities, clientInfo: .acpx)
        let session = try await client.newSession(
            NewSessionRequest(cwd: directory.resolvingSymlinksInPath().path))

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

    @Test func anAdvertisedReadIsServed() async throws {
        let text = try await runRead(capabilities: .headlessController)
        #expect(text == "read:contents")
    }

    @Test func anUnadvertisedReadIsRefused() async throws {
        let withoutFs = ClientCapabilities(
            fs: FileSystemCapability(readTextFile: false, writeTextFile: false), terminal: false)
        let text = try await runRead(capabilities: withoutFs)

        #expect(text.hasPrefix("error:"))
        // Not "no handler configured" — the method is not there at all, which is what
        // acpx achieves by never registering it.
        #expect(!text.contains("read:contents"))
    }
}
