import ACP
import Foundation
import JSONValue

/// The agent-side handle for one ACP session.
///
/// Passed to ``ACPAgentHandler/prompt(_:session:)``, it lets the agent stream
/// `session/update` notifications to the client, call back to the client
/// (permission prompts, file I/O), and observe cooperative cancellation.
public final class ACPServerSession: @unchecked Sendable {
    public let id: SessionId
    private let connection: JSONRPCConnection
    private let cancelLock = NSLock()
    private var cancelled = false

    init(id: SessionId, connection: JSONRPCConnection) {
        self.id = id
        self.connection = connection
    }

    // MARK: Streaming updates (agent → client)

    /// Send one `session/update` notification for this session.
    public func update(_ update: SessionUpdate) async {
        let note = SessionNotification(sessionId: id, update: update)
        guard let params = try? JSONValue(encoding: note) else { return }
        try? await connection.sendNotification(method: "session/update", params: params)
    }

    /// Stream a chunk of the agent's reply text.
    public func sendText(_ text: String) async { await update(.agentMessageChunk(.text(text))) }
    /// Stream a chunk of the agent's reasoning/thinking.
    public func sendThought(_ text: String) async { await update(.agentThoughtChunk(.text(text))) }
    /// Announce a tool call (typically `status: .inProgress`).
    public func sendToolCall(_ toolCall: ToolCall) async { await update(.toolCall(toolCall)) }
    /// Update a previously announced tool call (e.g. `status: .completed` + output).
    public func sendToolCallUpdate(_ toolCallUpdate: ToolCallUpdate) async {
        await update(.toolCallUpdate(toolCallUpdate))
    }
    /// Publish/replace the agent's plan for the turn.
    public func sendPlan(_ entries: [PlanEntry]) async { await update(.plan(entries)) }
    /// Advertise the session's available slash commands (the client renders these
    /// as its slash menu). Send again to update the set.
    public func sendAvailableCommands(_ commands: [AvailableCommand]) async {
        await update(.availableCommandsUpdate(commands))
    }

    // MARK: Client requests (agent → client → agent)

    /// Ask the client to approve a tool call. Throws if the client advertised no
    /// permission handler or the request fails.
    public func requestPermission(
        toolCall: ToolCallUpdate, options: [PermissionOption]
    ) async throws -> RequestPermissionResponse {
        let request = RequestPermissionRequest(sessionId: id, toolCall: toolCall, options: options)
        let result = try await connection.sendRequest(
            method: "session/request_permission", params: try JSONValue(encoding: request))
        return try result.decoded(RequestPermissionResponse.self)
    }

    /// Read a text file through the client (honours the client's `fs` capability).
    public func readTextFile(path: String, line: Int? = nil, limit: Int? = nil) async throws -> String {
        let request = ReadTextFileRequest(sessionId: id, path: path, line: line, limit: limit)
        let result = try await connection.sendRequest(
            method: "fs/read_text_file", params: try JSONValue(encoding: request))
        return try result.decoded(ReadTextFileResponse.self).content
    }

    /// Write a text file through the client.
    public func writeTextFile(path: String, content: String) async throws {
        let request = WriteTextFileRequest(sessionId: id, path: path, content: content)
        _ = try await connection.sendRequest(
            method: "fs/write_text_file", params: try JSONValue(encoding: request))
    }

    // MARK: Cancellation

    /// `true` once the client sent `session/cancel` for the in-flight turn. The
    /// running task is also Swift-cancelled, so `Task.isCancelled` works too.
    public var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    func markCancelled() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }
}
