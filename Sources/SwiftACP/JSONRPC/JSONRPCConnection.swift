import Foundation
import JSONFoundation

/// A JSON-RPC 2.0 peer over a `MessageTransport`.
///
/// Correlates our outbound requests with their responses, dispatches inbound
/// requests to a handler (concurrently, so a slow permission prompt can't stall
/// the read loop), and delivers notifications in arrival order.
public actor JSONRPCConnection {
    public typealias RequestHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCErrorBody>
    public typealias NotificationHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async -> Void

    private let transport: MessageTransport
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private var wireObserver: (@Sendable (String) -> Void)?
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    public init(transport: MessageTransport) {
        self.transport = transport
    }

    public func setHandlers(request: RequestHandler?, notification: NotificationHandler?) {
        self.requestHandler = request
        self.notificationHandler = notification
    }

    /// Observe every JSON-RPC message line on the wire, both directions, in
    /// chronological order — used to tee the raw protocol into the session event
    /// log. The closure is called synchronously, so it must be fast (enqueue, not
    /// block). Pass `nil` to stop observing.
    public func setWireObserver(_ observer: (@Sendable (String) -> Void)?) {
        self.wireObserver = observer
    }

    /// Begin reading inbound messages. Call once, after handlers are set.
    public func start() {
        guard readTask == nil else { return }
        let stream = transport.makeInboundStream()
        readTask = Task { [weak self] in
            do {
                for try await line in stream {
                    await self?.receive(line)
                }
            } catch {
                await self?.failAllPending(with: error)
            }
            await self?.handleStreamEnd()
        }
    }

    /// Suspends until the inbound stream ends (the peer disconnected / stdin hit
    /// EOF) or `close()` is called. A server loop awaits this to stay alive for
    /// the connection's lifetime. Returns immediately if reading never started.
    public func waitUntilClosed() async {
        await readTask?.value
    }

    // MARK: Sending

    /// Send a request and await its result as raw JSON.
    public func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = allocateId()
        let message = JSONRPCMessage.request(id: .integer(id), method: method, params: params)
        let line = encodeLine(message)
        return try await withCheckedThrowingContinuation { continuation in
            if isClosed {
                continuation.resume(throwing: TransportError.closed)
                return
            }
            pending[id] = continuation
            do {
                wireObserver?(line)
                try transport.write(line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func sendNotification(method: String, params: JSONValue?) throws {
        let line = encodeLine(JSONRPCMessage.notification(method: method, params: params))
        wireObserver?(line)
        try transport.write(line)
    }

    private func allocateId() -> Int {
        nextId += 1
        return nextId
    }

    // MARK: Receiving

    private func receive(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let message = try? JSONRPCMessage.decodeMessages(from: data).first else {
            // Adapters occasionally print non-JSON noise to stdout; ignore it.
            return
        }
        wireObserver?(line)

        switch message {
        case .request(let request):
            dispatchRequest(id: request.id, method: request.method, params: request.params)
        case .notification(let notification):
            await notificationHandler?(notification.method, notification.params)
        case .response, .errorResponse:
            if let id = message.id, let outcome = message.replyOutcome {
                resolveResponse(id: id, outcome: outcome)
            }
        }
    }

    private func resolveResponse(id: JSONRPCID, outcome: Result<JSONValue?, JSONRPCErrorBody>) {
        guard case .integer(let key) = id, let continuation = pending.removeValue(forKey: key) else {
            return
        }
        switch outcome {
        case .success(let result):
            continuation.resume(returning: result ?? .null)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func dispatchRequest(id: JSONRPCID, method: String, params: JSONValue?) {
        let handler = requestHandler
        Task { [weak self] in
            let outcome: Result<JSONValue, JSONRPCErrorBody>
            if let handler {
                outcome = await handler(method, params)
            } else {
                outcome = .failure(.methodNotFound(method))
            }
            await self?.sendReply(id: id, outcome: outcome)
        }
    }

    private func sendReply(id: JSONRPCID, outcome: Result<JSONValue, JSONRPCErrorBody>) {
        let message: JSONRPCMessage
        switch outcome {
        case .success(let result):
            message = .response(id: id, result: result)
        case .failure(let error):
            message = .errorResponse(id: id, error: error)
        }
        let line = encodeLine(message)
        wireObserver?(line)
        try? transport.write(line)
    }

    private func handleStreamEnd() {
        failAllPending(with: TransportError.closed)
    }

    private func failAllPending(with error: Error) {
        let waiters = pending
        pending = [:]
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        transport.close()
        failAllPending(with: TransportError.closed)
    }
}

/// Encode a JSON-RPC message as a single compact wire line (no embedded newlines).
private func encodeLine(_ message: JSONRPCMessage) -> String {
    (try? message.encodedString()) ?? "{}"
}
