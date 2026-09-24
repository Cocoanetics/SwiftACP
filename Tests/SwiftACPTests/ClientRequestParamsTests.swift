@testable import SwiftACP
import Foundation
import JSONFoundation
import Testing

/// How the client reads the params of the agent's requests (#100), as acpx's ACP SDK
/// reads them: a request whose required members are missing or do not fit is refused
/// with `Invalid params` and zod's issues, and any other member that does not fit is
/// read as absent. The refusals expected are acpx 0.19.1's (`acpx-client-params.json`).
@Suite(.timeLimit(.minutes(1)))
struct ClientRequestParamsTests {
    private struct Case: Decodable {
        let method: String
        let params: JSONValue?
        let error: JSONRPCErrorBody

        enum CodingKeys: String, CodingKey { case method, params, error }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            // Params that are absent and params that are null are different requests (and a
            // `nil` in `contains ? decode : nil` would be `JSONValue.null`).
            if container.contains(.params) {
                params = try container.decode(JSONValue.self, forKey: .params)
            } else {
                params = nil
            }
            error = try container.decode(JSONRPCErrorBody.self, forKey: .error)
        }
    }

    private static func cases() throws -> [Case] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-client-params.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixture))
    }

    /// What reached the client's handlers.
    actor Received {
        private(set) var reads: [ReadTextFileRequest] = []
        private(set) var permissions: [RequestPermissionRequest] = []

        func add(_ read: ReadTextFileRequest) { reads.append(read) }
        func add(_ permission: RequestPermissionRequest) { permissions.append(permission) }
    }

    private static func client(
        _ received: Received, _ terminals: TerminalRoutingTests.RecordingTerminals
    ) async -> ACPAgentConnection {
        let client = ACPAgentConnection(transport: LoopbackTransport.pair().0)
        await client.setFileSystemAccess(.unrestricted)
        await client.setTerminalHandler(terminals)
        await client.setHandlers(ACPClientHandlers(
            requestPermission: { request in
                await received.add(request)
                return .selected(request.options[0].optionId)
            },
            readTextFile: { request in
                await received.add(request)
                return ReadTextFileResponse(content: "")
            },
            writeTextFile: { _ in WriteTextFileResponse() }))
        return client
    }

    private static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Each of acpx's refusals, word for word: zod's `format()` of every member the
    /// schema requires that is missing or does not fit, nested by path. Nothing of the
    /// request reaches a handler.
    @Test func paramsTheSchemaRefusesAreAnsweredAsAcpxAnswersThem() async throws {
        let cases = try Self.cases()
        #expect(cases.count == 27)
        let received = Received()
        let terminals = TerminalRoutingTests.RecordingTerminals()
        let client = await Self.client(received, terminals)
        for testCase in cases {
            let result = await client.handleIncomingRequest(method: testCase.method, params: testCase.params)
            let request = "\(testCase.method) \(testCase.params.map { "\($0)" } ?? "without params")"
            guard case .failure(let error) = result else {
                Issue.record("\(request) was served")
                continue
            }
            #expect(error == testCase.error, "\(request)")
        }
        #expect(await received.reads.isEmpty)
        #expect(await received.permissions.isEmpty)
        #expect(await terminals.created.isEmpty)
    }

    /// A member the schema reads leniently never fails a request: one that does not fit
    /// is read as absent, and a list keeps only the entries that fit — as acpx served
    /// these same requests.
    @Test func membersReadLenientlyAreDroppedWhenTheyDoNotFit() async throws {
        let received = Received()
        let terminals = TerminalRoutingTests.RecordingTerminals()
        let client = await Self.client(received, terminals)
        for read in [
            #"{"sessionId":"s","path":"/f","line":"a","limit":-1,"_meta":5}"#,
            #"{"sessionId":"s","path":"/f","line":2,"limit":1.5}"#,
            #"{"sessionId":"s","path":"/f","line":4294967296,"limit":null}"#
        ] {
            let result = await client.handleIncomingRequest(method: "fs/read_text_file", params: try Self.json(read))
            if case .failure = result { Issue.record("\(read) refused: \(result)") }
        }
        let reads = await received.reads
        #expect(reads.map(\.line) == [nil, 2, nil])
        #expect(reads.map(\.limit) == [nil, nil, nil])

        for create in [
            #"{"sessionId":"s","command":"echo","args":[1,"hi",null,"there"],"env":"x","cwd":3,"#
                + #""outputByteLimit":"x","_meta":[]}"#,
            #"{"sessionId":"s","command":"printenv","args":["A"],"#
                + #""env":[{"name":"A","value":"1"},{"name":5,"value":"2"},{"name":"B"},"junk"]}"#
        ] {
            let result = await client.handleIncomingRequest(method: "terminal/create", params: try Self.json(create))
            if case .failure = result { Issue.record("\(create) refused: \(result)") }
        }
        let created = await terminals.created
        #expect(created.map(\.args) == [["hi", "there"], ["A"]])
        #expect(created.map(\.env) == [[], [EnvVariable(name: "A", value: "1")]])
        #expect(created.map(\.cwd) == [nil, nil])
        #expect(created.map(\.outputByteLimit) == [nil, nil])

        let permission = #"{"sessionId":"s","toolCall":{"toolCallId":"t","kind":"nope","status":3,"title":4,"#
            + #""content":5,"locations":[{"line":1}]},"options":[{"optionId":"o","name":"n","kind":"allow_once","#
            + #""_meta":3}]}"#
        let result = await client.handleIncomingRequest(
            method: "session/request_permission", params: try Self.json(permission))
        #expect(try result.get() == Self.json(#"{"outcome":{"outcome":"selected","optionId":"o"}}"#))
        let toolCall = try #require(await received.permissions.first?.toolCall)
        #expect(toolCall.kind == nil && toolCall.status == nil && toolCall.title == nil && toolCall.content == nil)
        #expect(toolCall.locations?.isEmpty == true)
        // Dropped, not made null: a null member of an update clears what it names.
        #expect(toolCall.nullMembers.isEmpty)
    }
}
