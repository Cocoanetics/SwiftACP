@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// Whether an agent may read a file (#91). acpx refuses `fs/read_text_file` under
/// `--deny-all`, with `Permission denied for fs/read_text_file (--deny-all)`, and serves
/// it in every other mode. Before this, SwiftACP served the read under `--deny-all`.
@Suite(.timeLimit(.minutes(1)))
struct ReadGateTests {
    /// An agent that asks the client to read `path`, and reports the outcome —
    /// including the error's shape.
    struct ReadProbeAgent: ACPAgentHandler {
        var path: String

        func initialize(_ request: InitializeRequest) async -> InitializeResponse {
            InitializeResponse(agentInfo: Implementation(name: "read-probe", version: "1.0"))
        }

        func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "read-session")
        }

        func prompt(
            _ request: PromptRequest, session: ACPServerSession
        ) async throws -> PromptResponse {
            do {
                await session.sendText("read:" + (try await session.readTextFile(path: path)))
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

    private let gate = WriteGateTests()

    private func readRun(_ policy: PermissionPolicy) async throws -> WriteGateTests.Run {
        let root = try gate.workspace()
        try "secret".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        return try await gate.run(
            ReadProbeAgent(path: root + "/notes.txt"), cwd: root,
            handlers: .standard(permission: policy))
    }

    /// `--deny-all` refuses the read in acpx's shape and words, and counts it as a
    /// denial — the turn then exits as a permission failure.
    @Test func denyAllRefusesTheRead() async throws {
        let run = try await readRun(.denyAll)
        #expect(run.reply == "error|-32603|Internal error|Permission denied for fs/read_text_file (--deny-all)")
        #expect(run.stats.denied == 1)
        #expect(run.stats.deniedEverything)
        #expect(run.failures == ["Permission denied for fs/read_text_file (--deny-all)"])
    }

    /// Every other mode serves the read, and counts nothing.
    @Test func otherModesServeTheRead() async throws {
        for policy in [PermissionPolicy.approveAll, .approveReads, .custom({ _ in .cancelled })] {
            let run = try await readRun(policy)
            #expect(run.reply == "read:secret")
            #expect(run.stats == PermissionStats())
            #expect(run.received == ["fs/read_text_file"])
        }
    }

    @Test func theRefusalCarriesAcpxsWording() {
        #expect(FileSystemPermissionError.readDenied.description
            == "Permission denied for fs/read_text_file (--deny-all)")
    }
}
