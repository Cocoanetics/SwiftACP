import Foundation
import JSONFoundation
import JSONRPCPeer
#if os(macOS) || os(Linux) || os(Windows)
import JSONRPCSubprocess
import JSONRPCWire
#endif

/// Serves an ``ACPAgentHandler`` over a `JSONRPCMessageTransport`.
///
/// It decodes inbound ACP requests/notifications, manages per-session state and
/// cooperative cancellation, and lets the handler stream `session/update`s back
/// through an ``ACPServerSession``. The peer plumbing (request↔response
/// correlation, concurrent dispatch, the wire) is the same `JSONRPCPeer`
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
    private let transport: JSONRPCMessageTransport
    private let connection: JSONRPCPeer
    private var sessions: [SessionId: ACPServerSession] = [:]
    private var inflight: [SessionId: Task<PromptResponse, Error>] = [:]
    private var clientCapabilities: ClientCapabilities?

    public init(handler: ACPAgentHandler, transport: JSONRPCMessageTransport) {
        self.handler = handler
        self.transport = transport
        connection = JSONRPCPeer(transport: transport)
    }

    #if os(macOS) || os(Linux) || os(Windows)
    /// Serve over the process's own stdio until the client disconnects (stdin EOF).
    ///
    /// Desktop-only, like everything stdio: an ACP agent is a child process the
    /// client spawned, which doesn't exist on iOS/Android — embed the server over a
    /// `LoopbackTransport` there instead.
    ///
    /// - Important: stdout must carry JSON-RPC *only*. Route the agent's own logs to
    ///   stderr, or the client will see them as protocol noise.
    public static func serveStdio(handler: ACPAgentHandler) async throws {
        let transport = StdioTransport(endpoint: .currentProcess, framing: LineFraming())
        try await ACPAgentServer(handler: handler, transport: transport).run()
    }
    #endif

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
        let session = try session(for: request.sessionId)
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
        try await handler.setMode(request, session: session(for: request.sessionId))
        return .object([:])
    }

    private func onSetConfigOption(_ params: JSONValue?) async throws -> JSONValue {
        let request: SetSessionConfigOptionRequest = try decode(params)
        let response = try await handler.setConfigOption(
            request, session: session(for: request.sessionId))
        return try encode(response)
    }

    /// The live ``ACPServerSession`` for `id`, or a JSON-RPC error if the client
    /// addressed a session it never opened (or that a fresh process doesn't know).
    private func session(for id: SessionId) throws -> ACPServerSession {
        guard let session = sessions[id] else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(id)")
        }
        return session
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
