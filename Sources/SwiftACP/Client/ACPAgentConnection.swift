import Foundation
import JSONValue

/// The protocol-level ACP client connection over a transport.
///
/// This is the mid-level API: it speaks every ACP method, routes inbound
/// client-side requests to your `ACPClientHandlers`, and fans `session/update`
/// notifications out to any number of subscribers. Most callers use the
/// higher-level ``ACPAgent``/``ACPSession`` wrappers instead.
public actor ACPAgentConnection {
    private let rpc: JSONRPCConnection
    private var handlers: ACPClientHandlers
    private var updateSinks: [UUID: AsyncStream<SessionNotification>.Continuation] = [:]

    public init(transport: MessageTransport, handlers: ACPClientHandlers = ACPClientHandlers()) {
        self.rpc = JSONRPCConnection(transport: transport)
        self.handlers = handlers
    }

    public func setHandlers(_ handlers: ACPClientHandlers) {
        self.handlers = handlers
    }

    /// Tee every JSON-RPC line on the wire (both directions) to `observer`, in
    /// chronological order — used to persist the session event log. Pass `nil` to
    /// stop. The closure runs synchronously, so it must be fast.
    public func setWireObserver(_ observer: (@Sendable (String) -> Void)?) async {
        await rpc.setWireObserver(observer)
    }

    private var onClientRequest: (@Sendable (String) -> Void)?

    /// Observe each outgoing agent request method (e.g. `initialize`,
    /// `session/new`) as it is sent — used to render acpx's `[client]` progress
    /// lines. The closure runs synchronously, so it must be fast.
    public func setClientRequestObserver(_ observer: (@Sendable (String) -> Void)?) {
        onClientRequest = observer
    }

    /// Wire inbound routing and begin reading. Call once before any request.
    public func start() async {
        await rpc.setHandlers(
            request: { [weak self] method, params in
                guard let self else { return .failure(.internalError("connection released")) }
                return await self.handleIncomingRequest(method: method, params: params)
            },
            notification: { [weak self] method, params in
                await self?.handleIncomingNotification(method: method, params: params)
            })
        await rpc.start()
    }

    public func close() {
        for sink in updateSinks.values { sink.finish() }
        updateSinks.removeAll()
        Task { await rpc.close() }
    }

    // MARK: - Subscriptions

    /// A new stream of every `session/update` notification across all sessions.
    /// Subscribe before prompting so no updates are missed.
    public func updates() -> AsyncStream<SessionNotification> {
        makeSubscription().stream
    }

    /// Like ``updates()`` but also returns a token so the caller can deliberately
    /// end the stream (draining buffered values first) — used by one-shot helpers.
    public func makeSubscription() -> (id: UUID, stream: AsyncStream<SessionNotification>) {
        var capturedId = UUID()
        let stream = AsyncStream<SessionNotification> { continuation in
            let id = UUID()
            capturedId = id
            updateSinks[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSink(id) }
            }
        }
        return (capturedId, stream)
    }

    /// Finish a subscription's stream; the consumer still receives buffered values.
    public func endSubscription(_ id: UUID) {
        updateSinks[id]?.finish()
    }

    private func removeSink(_ id: UUID) {
        updateSinks[id] = nil
    }

    // MARK: - Agent methods

    public func initialize(
        capabilities: ClientCapabilities,
        clientInfo: Implementation? = nil
    ) async throws -> InitializeResponse {
        try await send(
            "initialize",
            InitializeRequest(clientCapabilities: capabilities, clientInfo: clientInfo))
    }

    public func authenticate(methodId: String) async throws {
        let _: EmptyResponse = try await send("authenticate", AuthenticateRequest(methodId: methodId))
    }

    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        try await send("session/new", request)
    }

    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        try await send("session/load", request)
    }

    public func resumeSession(_ request: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await send("session/resume", request)
    }

    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        try await send("session/prompt", request)
    }

    public func setMode(_ request: SetSessionModeRequest) async throws {
        let _: EmptyResponse = try await send("session/set_mode", request)
    }

    @discardableResult
    public func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws
        -> SetSessionConfigOptionResponse {
        try await send("session/set_config_option", request)
    }

    public func setModel(_ request: SetSessionModelRequest) async throws {
        let _: EmptyResponse = try await send("session/set_model", request)
    }

    /// `session/cancel` is a notification — fire and forget.
    public func cancel(sessionId: SessionId) async throws {
        let params = try JSONValue(encoding: CancelNotification(sessionId: sessionId))
        try await rpc.sendNotification(method: "session/cancel", params: params)
    }

    // MARK: - Request plumbing

    private func send<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        onClientRequest?(method)
        let paramsValue = try JSONValue(encoding: params)
        let result = try await rpc.sendRequest(method: method, params: paramsValue)
        if R.self == EmptyResponse.self, let empty = EmptyResponse() as? R { return empty }
        return try result.decoded(R.self)
    }

    // MARK: - Inbound routing

    private func handleIncomingRequest(
        method: String, params: JSONValue?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        switch method {
        case "fs/read_text_file":
            return await route(params, handlers.readTextFile)
        case "fs/write_text_file":
            return await route(params, handlers.writeTextFile)
        case "session/request_permission":
            guard let handler = handlers.requestPermission else {
                return .failure(.methodNotFound(method))
            }
            do {
                let request: RequestPermissionRequest = try decode(params)
                let response = await handler(request)
                return .success(try JSONValue(encoding: response))
            } catch let error as JSONRPCErrorBody {
                return .failure(error)
            } catch {
                return .failure(.internalError(error.localizedDescription))
            }
        default:
            return .failure(.methodNotFound(method))
        }
    }

    /// Decode params, run a throwing handler, encode the response — or map a
    /// missing handler to "method not found".
    private func route<Request: Decodable & Sendable, Response: Encodable & Sendable>(
        _ params: JSONValue?,
        _ handler: (@Sendable (Request) async throws -> Response)?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard let handler else { return .failure(.init(code: -32601, message: "Method not supported")) }
        do {
            let request: Request = try decode(params)
            let response = try await handler(request)
            return .success(try JSONValue(encoding: response))
        } catch let error as JSONRPCErrorBody {
            return .failure(error)
        } catch {
            return .failure(.internalError(error.localizedDescription))
        }
    }

    private func decode<T: Decodable>(_ params: JSONValue?) throws -> T {
        guard let params else {
            throw JSONRPCErrorBody.invalidParams("missing params")
        }
        return try params.decoded(T.self)
    }

    private func handleIncomingNotification(method: String, params: JSONValue?) async {
        guard method == "session/update", let params,
            let notification = try? params.decoded(SessionNotification.self)
        else { return }
        for sink in updateSinks.values {
            sink.yield(notification)
        }
    }
}

/// Used for ACP methods whose result body is empty (`{}`).
struct EmptyResponse: Codable, Sendable {}
