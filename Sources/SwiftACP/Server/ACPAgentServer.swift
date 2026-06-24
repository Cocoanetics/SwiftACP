import Foundation
import JSONValue

/// Serves an ``ACPAgentHandler`` over a `MessageTransport`.
///
/// It decodes inbound ACP requests/notifications, manages per-session state and
/// cooperative cancellation, and lets the handler stream `session/update`s back
/// through an ``ACPServerSession``. The peer plumbing (request↔response
/// correlation, concurrent dispatch, the wire) is the same `JSONRPCConnection`
/// the ACP *client* uses — just driven from the server seam.
///
/// Typical CLI entry point:
/// ```swift
/// @main struct MyAgent {
///     static func main() async throws {
///         try await ACPAgentServer.serveStdio(handler: MyHandler())
///     }
/// }
/// ```
public actor ACPAgentServer {
    private let handler: ACPAgentHandler
    private let transport: MessageTransport
    private let connection: JSONRPCConnection
    private var sessions: [SessionId: ACPServerSession] = [:]
    private var inflight: [SessionId: Task<PromptResponse, Error>] = [:]
    private var clientCapabilities: ClientCapabilities?

    public init(handler: ACPAgentHandler, transport: MessageTransport) {
        self.handler = handler
        self.transport = transport
        connection = JSONRPCConnection(transport: transport)
    }

    /// Serve over the process's own stdio until the client disconnects (stdin EOF).
    public static func serveStdio(handler: ACPAgentHandler) async throws {
        try await ACPAgentServer(handler: handler, transport: StdioTransport()).run()
    }

    /// Wire handlers, start reading, and block until the client disconnects.
    public func run() async throws {
        await connection.setHandlers(
            request: { [weak self] method, params in
                guard let self else { return .failure(.internalError("server released")) }
                return await self.handleRequest(method, params)
            },
            notification: { [weak self] method, params in
                await self?.handleNotification(method, params)
            })
        await connection.start()
        await connection.waitUntilClosed()
    }

    /// The client capabilities reported at `initialize` (fs/terminal availability).
    public var advertisedClientCapabilities: ClientCapabilities? { clientCapabilities }

    // MARK: - Request dispatch

    private func handleRequest(_ method: String, _ params: JSONValue?)
        async -> Result<JSONValue, JSONRPCErrorBody> {
        do {
            switch method {
            case "initialize": return await .success(try onInitialize(params))
            case "authenticate": return await .success(try onAuthenticate(params))
            case "session/new": return await .success(try onNewSession(params))
            case "session/load", "session/resume": return await .success(try onLoadSession(params))
            case "session/prompt": return await .success(try onPrompt(params))
            case "session/set_mode": return await .success(try onSetMode(params))
            case "session/set_config_option": return await .success(try onSetConfigOption(params))
            case "session/set_model": return await .success(try onSetModel(params))
            default: return .failure(.methodNotFound(method))
            }
        } catch let error as JSONRPCErrorBody {
            return .failure(error)
        } catch {
            return .failure(.internalError(error.localizedDescription))
        }
    }

    private func onInitialize(_ params: JSONValue?) async throws -> JSONValue {
        let request: InitializeRequest = try decode(params)
        clientCapabilities = request.clientCapabilities
        return try await encode(handler.initialize(request))
    }

    private func onAuthenticate(_ params: JSONValue?) async throws -> JSONValue {
        let request: AuthenticateRequest = try decode(params)
        try await handler.authenticate(methodId: request.methodId)
        return .object([:])
    }

    private func onNewSession(_ params: JSONValue?) async throws -> JSONValue {
        let request: NewSessionRequest = try decode(params)
        let response = try await handler.newSession(request)
        let session = ACPServerSession(id: response.sessionId, connection: connection)
        sessions[response.sessionId] = session
        // Publish slash commands after the session/new reply (fire-and-forget).
        Task { await self.publishCommands(for: session) }
        return try encode(response)
    }

    private func onLoadSession(_ params: JSONValue?) async throws -> JSONValue {
        let request: LoadSessionRequest = try decode(params)
        let session = sessions[request.sessionId]
            ?? ACPServerSession(id: request.sessionId, connection: connection)
        sessions[request.sessionId] = session
        let encoded = try await encode(handler.loadSession(request, session: session))
        Task { await self.publishCommands(for: session) }
        return encoded
    }

    /// Publish the handler's advertised slash commands for a session, if any.
    private func publishCommands(for session: ACPServerSession) async {
        let commands = await handler.availableCommands(for: session.id)
        if !commands.isEmpty { await session.sendAvailableCommands(commands) }
    }

    private func onPrompt(_ params: JSONValue?) async throws -> JSONValue {
        let request: PromptRequest = try decode(params)
        guard let session = sessions[request.sessionId] else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(request.sessionId)")
        }
        // Run the turn as a cancellable task so `session/cancel` can interrupt it
        // (actor reentrancy lets the cancel notification land while we await).
        let task = Task { try await handler.prompt(request, session: session) }
        inflight[request.sessionId] = task
        defer { inflight[request.sessionId] = nil }
        do {
            return try await encode(try task.value)
        } catch is CancellationError {
            return try encode(PromptResponse(stopReason: .cancelled))
        }
    }

    private func onSetMode(_ params: JSONValue?) async throws -> JSONValue {
        let request: SetSessionModeRequest = try decode(params)
        try await handler.setMode(request)
        return .object([:])
    }

    private func onSetConfigOption(_ params: JSONValue?) async throws -> JSONValue {
        let request: SetSessionConfigOptionRequest = try decode(params)
        try await handler.setConfigOption(request)
        return .object([:])
    }

    private func onSetModel(_ params: JSONValue?) async throws -> JSONValue {
        let request: SetSessionModelRequest = try decode(params)
        try await handler.setModel(request)
        return .object([:])
    }

    // MARK: - Notification dispatch

    private func handleNotification(_ method: String, _ params: JSONValue?) async {
        guard method == "session/cancel", let params,
            let note = try? params.decoded(CancelNotification.self) else { return }
        sessions[note.sessionId]?.markCancelled()
        inflight[note.sessionId]?.cancel()
        await handler.cancel(sessionId: note.sessionId)
    }

    // MARK: - Codec helpers

    private func decode<T: Decodable>(_ params: JSONValue?) throws -> T {
        guard let params else { throw JSONRPCErrorBody.invalidParams("missing params") }
        return try params.decoded(T.self)
    }

    private func encode(_ value: some Encodable) throws -> JSONValue {
        try JSONValue(encoding: value)
    }
}
