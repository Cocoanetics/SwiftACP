import ACP

/// What an app implements to expose itself as an ACP agent.
///
/// ``ACPAgentServer`` decodes inbound ACP requests and dispatches them here.
/// Only ``initialize(_:)``, ``newSession(_:)`` and ``prompt(_:session:)`` are
/// required — the rest ship default implementations that report the feature as
/// unsupported (matching how minimal agents behave).
public protocol ACPAgentHandler: Sendable {
    /// The agent's capabilities + identity. Called once, before any session.
    func initialize(_ request: InitializeRequest) async -> InitializeResponse

    /// Create a fresh session rooted at `request.cwd`. Return its id (and,
    /// optionally, available modes / model advertisement).
    func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse

    /// Run one prompt turn. Stream `session/update`s via `session`, and return
    /// the stop reason — plus token `usage` when the provider reports it.
    func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse

    /// Authenticate with one of the agent's advertised methods. Default: no-op.
    func authenticate(methodId: String) async throws

    /// Reconnect to a previously created session (`session/load`/`session/resume`).
    /// Default: throws "not supported".
    func loadSession(_ request: LoadSessionRequest, session: ACPServerSession) async throws
        -> LoadSessionResponse

    /// The client requested cancellation of the in-flight turn. The running task
    /// is already Swift-cancelled and `session.isCancelled` is set; override only
    /// to add side effects. Default: no-op.
    func cancel(sessionId: SessionId) async

    /// Switch the session mode. Default: throws "not supported".
    func setMode(_ request: SetSessionModeRequest) async throws

    /// Set a session config option. Default: throws "not supported".
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws
}

public extension ACPAgentHandler {
    func authenticate(methodId: String) async throws {}

    func loadSession(_ request: LoadSessionRequest, session: ACPServerSession) async throws
        -> LoadSessionResponse {
        throw JSONRPCErrorBody(code: -32601, message: "session/load is not supported")
    }

    func cancel(sessionId: SessionId) async {}

    func setMode(_ request: SetSessionModeRequest) async throws {
        throw JSONRPCErrorBody(code: -32601, message: "session/set_mode is not supported")
    }

    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws {
        throw JSONRPCErrorBody(code: -32601, message: "session/set_config_option is not supported")
    }
}
