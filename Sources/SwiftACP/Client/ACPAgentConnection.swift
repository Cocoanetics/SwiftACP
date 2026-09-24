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
    var handlers: ACPClientHandlers
    var updateSinks: [UUID: AsyncStream<SessionNotification>.Continuation] = [:]
    /// Subscribers to the richer ``ConnectionEvent`` stream: updates plus the client
    /// operations this connection reports.
    var eventSinks: [UUID: AsyncStream<ConnectionEvent>.Continuation] = [:]

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

    /// Runs the agent's `terminal/*` requests — see ``setTerminalHandler(_:)``.
    var terminalHandler: (any ACPTerminalHandler)?
    /// Set once ``shutDownTerminals()`` has run.
    var terminalsShutDown = false

    /// Widen or restore how far `fs/*` may reach. Containment is the default; an
    /// embedder that mediates filesystem access itself can opt out.
    public func setFileSystemAccess(_ scope: FileSystemAccessScope) {
        fileSystemAccess = scope
    }

    /// Each session's working directory, recorded from `session/new`, `session/load`
    /// and `session/resume` — the root `fs/*` paths are confined to.
    var sessionRoots: [SessionId: String] = [:]
    /// The `cwd` of each `session/new` still waiting for its answer.
    var sessionRootsBeingCreated: [UUID: String] = [:]
    /// Told each time a session is open (``setSessionOpenedObserver(_:)``).
    private var sessionOpened: (@Sendable () -> Void)?

    /// Sessions with a `session/prompt` in flight.
    private var promptingSessionIds: Set<SessionId> = []

    /// Sessions whose `session/update`s are not delivered — their `session/load` is
    /// replaying history the caller has — with how many loads asked. acpx's
    /// `suppressSessionUpdates`, kept per session: one connection can hold several.
    var replaySuppressed: [SessionId: Int] = [:]
    /// Each session's `session/update`s as they are read and as they are handled: what
    /// the replay drain watches go quiet (see ``SessionUpdateLedger``).
    nonisolated let sessionUpdates = SessionUpdateLedger()
    /// Sessions a `session/load` is in progress for, with the loads of each waiting
    /// their turn (see ``loadSession(_:suppressReplayUpdates:rawWire:)``).
    var loadWaiters: [SessionId: [CheckedContinuation<Void, Never>]] = [:]

    /// How each session's latest turn settled its permissions; reset when a turn
    /// starts. See ``permissionStats(for:)``.
    var turnPermissionStats: [SessionId: PermissionStats] = [:]

    /// How the permissions asked for during `sessionId`'s latest turn were settled —
    /// read it once the turn returns to decide the exit code, as acpx does.
    public func permissionStats(for sessionId: SessionId) -> PermissionStats {
        turnPermissionStats[sessionId] ?? PermissionStats()
    }
    /// Sessions whose in-flight turn this client is cancelling (`session/cancel`
    /// sent, prompt not yet returned). A permission request answered meanwhile is
    /// still resolved as usual, but a refusal isn't explained — the caller is ending
    /// the turn itself. Mirrors acpx's `cancellingSessionIds`.
    var cancellingSessionIds: Set<SessionId> = []

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
        wireObserver.set(observer)
    }

    /// The caller's wire observer; the peer's wire hook (installed once, in `start`)
    /// forwards to it, since it also counts the agent's requests as they arrive.
    private let wireObserver = WireObserverBox()
    /// The agent's requests that arrived and are not yet answered, per session — what
    /// a turn waits for before it ends. See ``InboundRequestLedger``.
    let inboundRequests = InboundRequestLedger()

    private var onClientRequest: (@Sendable (String) -> Void)?

    /// Whether the connection has ended — the agent closed its end (it exited), or
    /// ``close()`` was called. Nothing sent on a closed connection can arrive, so a
    /// holder checks this before reusing it, as acpx's `hasLiveConnection` does.
    public private(set) var isClosed = false
    /// Resolves once the read loop has ended and ``isClosed`` is set.
    private var closeWatch: Task<Void, Never>?

    /// Suspends until the connection has ended (see ``isClosed``). Returns at once if
    /// it was never started.
    public func waitUntilClosed() async {
        await closeWatch?.value
    }

    private func markClosed() {
        isClosed = true
        // acpx retires an agent's terminals whenever its connection ends: a disconnected
        // agent can no longer release them. Not awaited, so the end of the connection is
        // not held up by commands being killed; `ACPAgent.close()` awaits it itself.
        if terminalHandler != nil { Task { await shutDownTerminals() } }
    }

    /// Whether `error` is this layer reporting the connection ended — a request sent
    /// after, or pending when, the agent exited or the connection was closed.
    public static func isConnectionClosed(_ error: Error) -> Bool {
        (error as? JSONRPCPeerError) == .closed || error is AgentDisconnectedError
    }

    /// Whether `error` came of the connection ending: it closed
    /// (``isConnectionClosed(_:)``), or the agent passed the message limit, which ends it
    /// (``AcpMessageLimitError``). The agent can still be running then, until what ends
    /// it — `ACPAgent.close()` awaits that — is done.
    public static func endedTheConnection(_ error: Error) -> Bool {
        isConnectionClosed(error) || error is AcpMessageLimitError
    }

    /// Forget that the connection ended, as if its end had been read but not yet
    /// recorded: lets a test reproduce a caller racing the agent's exit.
    func forgetClosedForTesting() {
        isClosed = false
    }

    /// Observe each outgoing agent request method (e.g. `initialize`,
    /// `session/new`) as it is sent — used to render acpx's `[client]` progress
    /// lines. The closure runs synchronously, so it must be fast.
    public func setClientRequestObserver(_ observer: (@Sendable (String) -> Void)?) {
        onClientRequest = observer
    }

    /// Wire inbound routing and begin reading. Call once before any request.
    public func start() async {
        // Runs inline as each message is read, in order: an agent request is counted
        // here, before the peer hands it to its own task, so a turn that ends after
        // reading it is sure to wait for it.
        await rpc.setWireLog { [wireObserver, inboundRequests, sessionUpdates] direction, message in
            if direction == .inbound, case .request(let request) = message,
                let sessionId = InboundRequestLedger.sessionId(of: request.params) {
                inboundRequests.arrived(sessionId)
            }
            if direction == .inbound, case .notification(let note) = message, note.method == "session/update",
                let sessionId = InboundRequestLedger.sessionId(of: note.params) {
                sessionUpdates.arrived(sessionId)
            }
            if let observer = wireObserver.current, let line = try? message.encodedString() {
                observer(line)
            }
        }
        await rpc.setHandlers(
            request: { [weak self, inboundRequests] method, params in
                defer {
                    if let sessionId = InboundRequestLedger.sessionId(of: params) {
                        inboundRequests.finished(sessionId)
                    }
                }
                guard let self else { return .failure(.internalError("connection released")) }
                return await self.serveIncomingRequest(method: method, params: params)
            },
            notification: { [weak self] method, params in
                await self?.handleIncomingNotification(method: method, params: params)
            })
        await rpc.start()
        // Note the end of the stream, whichever side ends it. It lives as long as the
        // read loop, which the agent exiting or `close()` ends.
        closeWatch = Task { [weak self, rpc] in
            await rpc.waitUntilClosed()
            await self?.markClosed()
        }
    }

    public func close() {
        // The agent's commands go too, as acpx retires its terminals when its client
        // closes. The task keeps the connection until they have; `ACPAgent.close()`
        // awaits the same shutdown itself.
        if terminalHandler != nil { Task { await shutDownTerminals() } }
        isClosed = true
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

    /// While the request is out, the agent can ask for a terminal or a file for the
    /// session it is creating, whose id the client does not know yet: those requests
    /// get this `cwd` (see ``sessionRoot(_:)``), as acpx's client answers them in its
    /// own, the session's.
    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        let creation = UUID()
        sessionRootsBeingCreated[creation] = request.cwd
        defer { sessionRootsBeingCreated[creation] = nil }
        let response: NewSessionResponse = try await send("session/new", request)
        sessionRoots[response.sessionId] = request.cwd
        sessionOpened?()
        return response
    }

    /// Run `observer` each time a session is open — `session/new`, `session/load` or
    /// `session/resume` answered — however it was opened. ``ACPAgent`` notes the agent's
    /// processes then, as acpx's `captureAgentDescendants` does.
    public func setSessionOpenedObserver(_ observer: (@Sendable () -> Void)?) {
        sessionOpened = observer
    }

    /// The root of `sessionId`: the one registered for it, else — for a session being
    /// created right now — the `cwd` its `session/new` asked for, when every creation
    /// in flight asked for the same one.
    func sessionRoot(_ sessionId: SessionId) -> String? {
        if let root = sessionRoots[sessionId] { return root }
        let creating = Set(sessionRootsBeingCreated.values)
        return creating.count == 1 ? creating.first : nil
    }

    /// The root is registered *before* the request is sent: this actor is reentrant at
    /// the `await`, and an agent handling `session/load` may issue `fs/*` for the very
    /// session being loaded. Registering afterwards would refuse those as an unknown
    /// session. A failed load restores whatever was there before.
    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            let response: LoadSessionResponse = try await send("session/load", request)
            sessionOpened?()
            return response
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    public func resumeSession(_ request: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        let previous = sessionRoots.updateValue(request.cwd, forKey: request.sessionId)
        do {
            let response: ResumeSessionResponse = try await send("session/resume", request)
            sessionOpened?()
            return response
        } catch {
            sessionRoots[request.sessionId] = previous
            throw error
        }
    }

    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        // Refuse content the agent never advertised, the way npm acpx's client does
        // in `normalizePromptForAgent`. Every path — `ACPSession.prompt`, `run`, the
        // daemon, an embedder's own call — funnels through here, so the check belongs
        // here rather than at each caller: an agent handed an image it did not claim
        // typically ignores it and answers anyway, which reads as a correct reply to
        // a question it never saw.
        let capabilities = initializeResult?.agentCapabilities?.promptCapabilities
        for (index, block) in request.prompt.enumerated() {
            guard let requirement = block.requiredPromptCapability,
                  !requirement.isAdvertised(by: capabilities)
            else { continue }
            throw UnsupportedPromptContentError(
                index: index, capability: requirement.rawValue,
                agent: initializeResult?.agentInfo?.name)
        }
        // A turn starts un-cancelled; whichever way it ends, it is no longer being
        // cancelled either (the bookkeeping acpx does around its active prompt).
        cancellingSessionIds.remove(request.sessionId)
        promptingSessionIds.insert(request.sessionId)
        turnPermissionStats[request.sessionId] = PermissionStats()
        defer {
            promptingSessionIds.remove(request.sessionId)
            cancellingSessionIds.remove(request.sessionId)
        }
        // The turn is not over until the agent's requests from it are answered: one it
        // sent without awaiting would otherwise be counted against the next turn.
        return try await answeringItsRequests(in: request.sessionId) {
            try await send("session/prompt", request)
        }
    }

    public func setMode(_ request: SetSessionModeRequest) async throws {
        try await answeringItsRequests(in: request.sessionId) {
            let _: EmptyResponse = try await send("session/set_mode", request)
        }
    }

    @discardableResult
    public func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws
        -> SetSessionConfigOptionResponse {
        try await answeringItsRequests(in: request.sessionId) {
            try await send("session/set_config_option", request)
        }
    }

    public func setModel(_ request: SetSessionModelRequest) async throws {
        try await answeringItsRequests(in: request.sessionId) {
            let _: EmptyResponse = try await send("session/set_model", request)
        }
    }

    /// Send a request whose answer can arrive before the answers to what the agent asked
    /// of the client meanwhile — a turn, or a control. Those requests belong to it, and
    /// are answered before this returns: afterwards they would be handled under
    /// whatever handlers the next caller put in place.
    private func answeringItsRequests<T>(in sessionId: SessionId, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await inboundRequests.waitUntilIdle(sessionId)
            return value
        } catch {
            await inboundRequests.waitUntilIdle(sessionId)
            throw error
        }
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

    func handleIncomingRequest(
        method: String, params: JSONValue?
    ) async -> Result<JSONValue, JSONRPCErrorBody> {
        switch method {
        case "fs/read_text_file":
            guard advertisedCapabilities?.fs.readTextFile != false else {
                return .failure(Self.methodNotFound(method))
            }
            return await routeFileSystem(
                method, params, access: .read, handlers.readTextFile, authorize: handlers.authorizeRead)
        case "fs/write_text_file":
            guard advertisedCapabilities?.fs.writeTextFile != false else {
                return .failure(Self.methodNotFound(method))
            }
            return await routeFileSystem(
                method, params, access: .write, handlers.writeTextFile,
                authorize: handlers.authorizeWrite)
        case _ where Self.terminalMethods.contains(method):
            return await routeTerminal(method, params)
        case "session/request_permission":
            guard let handler = handlers.requestPermission else {
                return .failure(Self.methodNotFound(method))
            }
            do {
                let request: RequestPermissionRequest = try decode(params, for: method)
                let response = try await resolvePermission(request, with: handler)
                return .success(try JSONValue(encoding: response))
            } catch let error as JSONRPCErrorBody {
                return .failure(error)
            } catch {
                return .failure(.internalError(error.localizedDescription))
            }
        default:
            return .failure(Self.methodNotFound(method))
        }
    }

    /// The params of a request for `method` as `T`, read as acpx's client reads them
    /// (``ClientRequestSchema``): refused with the ACP SDK's `Invalid params` and zod's
    /// issues when a member the method requires is missing or does not fit, and with any
    /// other member that does not fit read as absent.
    func decode<T: Decodable>(_ params: JSONValue?, for method: String) throws -> T {
        let schema = ClientRequestSchema.request(method)
        if let issues = schema?.issues(in: params), !issues.isEmpty {
            throw Self.invalidParams(issues: ClientRequestSchema.formatted(issues))
        }
        guard let params, let decoded = try? (schema?.lenient(params) ?? params).decoded(T.self) else {
            throw Self.invalidParams
        }
        return decoded
    }
}

/// Used for ACP methods whose result body is empty (`{}`).
struct EmptyResponse: Codable, Sendable {}
