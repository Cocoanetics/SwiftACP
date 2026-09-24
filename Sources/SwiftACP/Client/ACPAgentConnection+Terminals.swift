import Foundation
import JSONFoundation

// Serving the agent's `terminal/*` requests through the connection's
// ``ACPTerminalHandler``, with the turn's permission gate in front of `terminal/create`
// and acpx's error shapes on the way back.
//
// Split from `ACPAgentConnection.swift` to keep that file inside the 500-line limit;
// the members this reaches are internal rather than private so both halves can.
extension ACPAgentConnection {
    static let terminalMethods: Set<String> = [
        "terminal/create", "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release"
    ]

    /// Serve one `terminal/*` request. Not advertised, or with no handler to run it, the
    /// method is not found, as acpx registers the terminal methods only with the
    /// capability.
    func routeTerminal(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCErrorBody> {
        guard advertisedCapabilities?.terminal != false, let terminals = terminalHandler else {
            return .failure(Self.methodNotFound(method))
        }
        do {
            switch method {
            case "terminal/create":
                var request: CreateTerminalRequest = try decode(params)
                // acpx runs a command in its client's cwd — the session's — unless told
                // otherwise; a session this connection never opened has none, and the
                // handler's own is used.
                request.cwd = request.cwd ?? sessionRoots[request.sessionId]
                try await handlers.authorizeTerminal?(request)
                // Asking can take long; a connection that ended meanwhile has released its
                // terminals, and a command started now would outlive it. acpx rechecks its
                // control authority here and answers `Request cancelled`.
                guard !terminalsShutDown, !isClosed else { return .failure(Self.requestCancelled) }
                return .success(try JSONValue(encoding: try await terminals.createTerminal(request)))
            case "terminal/output":
                return .success(try JSONValue(encoding: try await terminals.terminalOutput(decode(params))))
            case "terminal/wait_for_exit":
                return .success(try JSONValue(encoding: try await terminals.waitForTerminalExit(decode(params))))
            case "terminal/kill":
                return .success(try JSONValue(encoding: try await terminals.killTerminal(decode(params))))
            default:
                return .success(try JSONValue(encoding: try await terminals.releaseTerminal(decode(params))))
            }
        } catch let error as JSONRPCErrorBody {
            return .failure(error)
        } catch is CancellationError {
            return .failure(Self.requestCancelled)
        } catch let error as PermissionPromptUnavailableError {
            // acpx's `recordPermissionError`: answered as cancelled, and noted, so the
            // turn fails on it once over.
            notePermissionRefusal(params, .cancelled, promptUnavailable: true)
            return .failure(FileSystemContainment.refused(error.description))
        } catch let error as TerminalError {
            if error == .permissionDenied { notePermissionRefusal(params, .denied) }
            return .failure(FileSystemContainment.refused(error.description))
        } catch {
            // Anything else reaches the agent the way the ACP SDK reports a thrown
            // error: `Internal error`, the message in `data.details`.
            return .failure(FileSystemContainment.refused(error.localizedDescription))
        }
    }

    /// Count a refused `terminal/create` in the turn's permission stats.
    private func notePermissionRefusal(
        _ params: JSONValue?, _ decision: PermissionStats.Decision, promptUnavailable: Bool = false
    ) {
        guard let sessionId = decodedSessionId(params) else { return }
        turnPermissionStats[sessionId, default: PermissionStats()].record(decision)
        if promptUnavailable { turnPermissionStats[sessionId]?.promptUnavailable = true }
    }

    // MARK: - Lifetime

    /// Run the agent's `terminal/*` requests on `handler` from now on — or refuse them,
    /// given `nil`. The handler lives as long as the connection: its terminals are
    /// released when the connection ends (see ``shutDownTerminals()``). A handler
    /// replaced by another is shut down first, since nothing could reach its terminals
    /// afterwards. One given once the terminals are being shut down is shut down at
    /// once instead: nothing would shut it down later.
    public func setTerminalHandler(_ handler: (any ACPTerminalHandler)?) async {
        guard !terminalsShutDown else {
            await handler?.shutdown()
            return
        }
        let previous = terminalHandler
        terminalHandler = handler
        if let previous, previous !== handler { await previous.shutdown() }
    }

    /// Release every terminal the agent still has open, as acpx does when its client
    /// closes — called when the connection ends, whichever side ends it. Only the first
    /// call does anything, with a handler or without one.
    public func shutDownTerminals() async {
        guard !terminalsShutDown else { return }
        terminalsShutDown = true
        await terminalHandler?.shutdown()
    }
}
