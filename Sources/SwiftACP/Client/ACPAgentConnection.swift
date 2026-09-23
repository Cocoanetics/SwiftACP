import Foundation
import JSONFoundation
import JSONRPCPeer

/// The protocol-level ACP client connection over a transport.
///
/// This is the mid-level API: it speaks every ACP method, routes inbound
/// client-side requests to your `ACPClientHandlers`, and fans `session/update`
/// notifications out to any number of subscribers. Most callers use the
/// higher-level ``ACPAgent``/``ACPSession`` wrappers instead.
public actor ACPAgentConnection {
    private let rpc: JSONRPCPeer
    private var handlers: ACPClientHandlers
    private var updateSinks: [UUID: AsyncStream<SessionNotification>.Continuation] = [:]
    /// Subscribers to the richer ``ConnectionEvent`` stream: updates plus the client
    /// operations this connection reports.
    private var eventSinks: [UUID: AsyncStream<ConnectionEvent>.Continuation] = [:]

    /// The agent's `initialize` response once the handshake succeeded. Its
    /// `agentInfo` identifies the adapter for the compatibility rules applied to
    /// permission requests (see ``CodexCompat``).
    public private(set) var initializeResult: InitializeResponse?

    /// The capabilities advertised to the agent in `initialize`. A method the client did
    /// not advertise is not served: acpx registers its `fs/*` and `terminal/*` handlers
    /// only when the matching capability is on, so an agent that calls one anyway gets
    /// method-not-found rather than the operation (`--no-fs`, `--no-terminal`).
    public private(set) var advertisedCapabilities: ClientCapabilities?

    /// How far an agent's `fs/*` requests may reach. Confined to each session's own
    /// working directory by default; an embedder that mediates filesystem access itself
    /// can set ``FileSystemAccessScope/unrestricted``.
    public private(set) var fileSystemAccess: FileSystemAccessScope = .sessionRoot

    /// Widen or restore how far `fs/*` may reach. Containment is the default; an
    /// embedder that mediates filesystem access itself can opt out.
    public func setFileSystemAccess(_ scope: FileSystemAccessScope) {
        fileSystemAccess = scope
    }

    /// Each session's working directory, recorded from `session/new`, `session/load`
    /// and `session/resume` — the root `fs/*` paths are confined to.
    private var sessionRoots: [SessionId: String] = [:]

    /// Sessions with a `session/prompt` in flight.
    private var promptingSessionIds: Set<SessionId> = []
    /// Sessions whose in-flight turn this client is cancelling (`session/cancel`
    /// sent, prompt not yet returned). A permission request answered meanwhile is
    /// still resolved as usual, but a refusal isn't explained — the caller is ending
    /// the turn itself. Mirrors acpx's `cancellingSessionIds`.
    private var cancellingSessionIds: Set<SessionId> = []

    public init(transport: JSONRPCMessageTransport, handlers: ACPClientHandlers = ACPClientHandlers()) {
        self.rpc = JSONRPCPeer(transport: transport)
        self.handlers = handlers
    }

    public func setHandlers(_ handlers: ACPClientHandlers) {
        self.handlers = handlers
    }

    /// Tee every JSON-RPC line on the wire (both directions) to `observer`, in
    /// chronological order — used to persist the session event log. Pass `nil` to
    /// stop. The closure runs synchronously, so it must be fast.
    ///
    /// Bridges JSONFoundation's `JSONRPCPeer.setWireLog`, which reports decoded
    /// ``JSONRPCMessage`` values, back to the line-oriented observer this layer
    /// exposes: each message is re-encoded to its canonical wire string.
    public func setWireObserver(_ observer: (@Sendable (String) -> Void)?) async {
        guard let observer else {
            await rpc.setWireLog(nil)
            return
        }
        await rpc.setWireLog { _, message in
            if let line = try? message.encodedString() { observer(line) }
        }
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
        for sink in eventSinks.values { sink.finish() }
        updateSinks.removeAll()
        eventSinks.removeAll()
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

    /// Like ``makeSubscription()``, but the stream carries every ``ConnectionEvent``
    /// — each `session/update` plus the client operations this connection reports
    /// (a permission refusal that may end the turn) — in wire order.
    public func makeEventSubscription() -> (id: UUID, stream: AsyncStream<ConnectionEvent>) {
        var capturedId = UUID()
        let stream = AsyncStream<ConnectionEvent> { continuation in
            let id = UUID()
            capturedId = id
            eventSinks[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSink(id) }
            }
        }
        return (capturedId, stream)
    }

    /// A new stream of every ``ConnectionEvent`` across all sessions. Subscribe
    /// before prompting so no event is missed.
    public func events() -> AsyncStream<ConnectionEvent> {
        makeEventSubscription().stream
    }

    /// Finish a subscription's stream; the consumer still receives buffered values.
    public func endSubscription(_ id: UUID) {
        updateSinks[id]?.finish()
        eventSinks[id]?.finish()
    }

    private func removeSink(_ id: UUID) {
        updateSinks[id] = nil
        eventSinks[id] = nil
    }

    // MARK: - Agent methods

    public func initialize(
        capabilities: ClientCapabilities,
        clientInfo: Implementation? = nil
    ) async throws -> InitializeResponse {
        advertisedCapabilities = capabilities
        let response: InitializeResponse = try await send(
            "initialize",
            InitializeRequest(clientCapabilities: capabilities, clientInfo: clientInfo))
        initializeResult = response
        return response
    }

    public func authenticate(methodId: String) async throws {
        let _: EmptyResponse = try await send("authenticate", AuthenticateRequest(methodId: methodId))
    }

    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        let response: NewSessionResponse = try await send("session/new", request)
        sessionRoots[response.sessionId] = request.cwd
        return response
    }

    /// The root is registered *before* the request is sent: this actor is reentrant at
    /// the `await`, and an agent handling `session/load` may issue `fs/*` for the very
    /// session being loaded. Registering afterwards would refuse those as an unknown
    /// session. A failed load restores whatever was there before.
    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            return try await send("session/load", request)
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    public func resumeSession(_ request: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            return try await send("session/resume", request)
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        // A turn starts un-cancelled; whichever way it ends, it is no longer being
        // cancelled either (the bookkeeping acpx does around its active prompt).
        cancellingSessionIds.remove(request.sessionId)
        promptingSessionIds.insert(request.sessionId)
        defer {
            promptingSessionIds.remove(request.sessionId)
            cancellingSessionIds.remove(request.sessionId)
        }
        return try await send("session/prompt", request)
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
        // Only a turn in flight can be "cancelling" (a stray cancel with no prompt
        // running has nothing to suppress); undone if the notification never left.
        let cancelling = promptingSessionIds.contains(sessionId)
        if cancelling { cancellingSessionIds.insert(sessionId) }
        do {
            try await rpc.sendNotification(method: "session/cancel", params: params)
        } catch {
            if cancelling { cancellingSessionIds.remove(sessionId) }
            throw error
        }
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
            guard advertisedCapabilities?.fs.readTextFile != false else {
                return .failure(.methodNotFound(method))
            }
            return await routeFileSystem(
                method, params, access: .read, handlers.readTextFile)
        case "fs/write_text_file":
            guard advertisedCapabilities?.fs.writeTextFile != false else {
                return .failure(.methodNotFound(method))
            }
            return await routeFileSystem(
                method, params, access: .write, handlers.writeTextFile)
        case "session/request_permission":
            guard let handler = handlers.requestPermission else {
                return .failure(.methodNotFound(method))
            }
            do {
                let request: RequestPermissionRequest = try decode(params)
                let response = await resolvePermission(request, with: handler)
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

    // MARK: - Permission requests

    /// Answer a `session/request_permission` through the configured handler, with
    /// the adapter-compatibility rules acpx applies at the client boundary (see
    /// ``CodexCompat``): Codex's non-aborting refusal is ranked first before the
    /// handler picks, and a refusal that may still end the turn is explained — as a
    /// ``ClientOperation`` on the event subscriptions (ahead of anything the agent
    /// sends in reaction) and as `_meta.acpx.permissionNotice` on the response.
    /// Nothing here approves an operation to keep a turn running.
    private func resolvePermission(
        _ request: RequestPermissionRequest,
        with handler: @Sendable (RequestPermissionRequest) async -> RequestPermissionResponse
    ) async -> RequestPermissionResponse {
        let agentName = initializeResult?.agentInfo?.name
        // Ahead of the handler: an Antigravity interaction question has no answer any
        // policy may give on the user's behalf, so it is cancelled rather than resolved.
        if AntigravityCompat.isInteractionQuestion(request, agentName: agentName) {
            let notice = AntigravityCompat.questionNotice
            announce(notice, sessionId: request.sessionId)
            return RequestPermissionResponse(outcome: .cancelled)
                .addingACPXMetadata(["permissionNotice": .string(notice)])
        }
        let response = await handler(CodexCompat.preferPermissionRefusal(request, agentName: agentName))
        guard let notice = CodexCompat.permissionNotice(
            request: request, response: response, agentName: agentName),
            !cancellingSessionIds.contains(request.sessionId),
            !isDeliberateCancellation(request, response)
        else { return response }
        announce(notice, sessionId: request.sessionId)
        return response.addingACPXMetadata(["permissionNotice": .string(notice)])
    }

    /// Serve one `fs/*` request, confining its path to the session's working directory
    /// first (see ``FileSystemAccessScope``). The handler only ever sees a path the
    /// client has already vouched for, so a custom handler inherits the containment.
    ///
    /// A session this connection never opened has no root to check against, so its
    /// requests are refused rather than served unchecked — an agent cannot reach out of
    /// the workspace by naming a session id we do not know.
    private func routeFileSystem<
        Request: FileSystemPathRequest & Decodable & Sendable, Response: Encodable & Sendable
    >(
        _ method: String, _ params: JSONValue?, access: FileSystemContainment.Access,
        _ handler: (@Sendable (Request) async throws -> Response)?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard let handler else { return .failure(.methodNotFound(method)) }
        do {
            var request: Request = try decode(params)
            if fileSystemAccess == .sessionRoot {
                guard let root = sessionRoots[request.sessionId] else {
                    return .failure(.invalidParams("Unknown session: \(request.sessionId)"))
                }
                request.path = try FileSystemContainment.resolve(
                    path: request.path, under: root, for: access)
            }
            let contained = request
            let response = try await handler(contained)
            return .success(try JSONValue(encoding: response))
        } catch let error as JSONRPCErrorBody {
            return .failure(error)
        } catch {
            return .failure(.internalError(error.localizedDescription))
        }
    }

    /// Report a permission notice to the event subscriptions, ahead of anything the
    /// agent sends in reaction to the answer.
    private func announce(_ notice: String, sessionId: SessionId) {
        let operation = ClientOperation(
            method: ClientOperation.requestPermission, status: .completed, summary: notice,
            sessionId: sessionId)
        for sink in eventSinks.values {
            sink.yield(.clientOperation(operation))
        }
    }

    /// Whether a handler cancelled outright although the agent offered a refusal it
    /// could have selected — acpx's explicit host `cancel` decision, which needs no
    /// explaining. The built-in policies only cancel when no refusal exists at all.
    private func isDeliberateCancellation(
        _ request: RequestPermissionRequest, _ response: RequestPermissionResponse
    ) -> Bool {
        guard case .cancelled = response.outcome else { return false }
        return request.options.contains { $0.kind == .rejectOnce || $0.kind == .rejectAlways }
    }

    private func handleIncomingNotification(method: String, params: JSONValue?) async {
        guard method == "session/update", let params,
            let notification = try? params.decoded(SessionNotification.self)
        else { return }
        for sink in updateSinks.values {
            sink.yield(notification)
        }
        for sink in eventSinks.values {
            sink.yield(.update(notification))
        }
    }
}

/// Used for ACP methods whose result body is empty (`{}`).
struct EmptyResponse: Codable, Sendable {}
