import Foundation
import SwiftACP

/// A session control the agent turned down — a mode, a model or a config option — as
/// acpx's client reports it (`src/acp/session-control-errors.ts`, 0.19.1). Its message
/// names the control; the agent's error it wraps stays its ACP error (acpx's
/// `wrapped.acp`), which output reports as the failure's own.
public struct SessionControlError: Error, LocalizedError, Equatable {
    public let message: String
    /// The agent's error, when the control failed with one.
    public let acp: AcpErrorPayload?

    public var errorDescription: String? { message }

    /// Run `request`, the session control `method`, its failure said as acpx's client says
    /// it (`maybeWrapSessionControlError`). `context` says what was asked, as
    /// `for mode "<id>"` does.
    public static func wrapping<T>(
        _ method: String, context: String, _ request: () async throws -> T
    ) async throws -> T {
        do {
            return try await request()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw wrap(error, method: method, context: context)
        }
    }

    /// Run `request`, the model control `method` for `modelId`, its failure said as acpx's
    /// `throwSessionModelError` says it.
    public static func wrappingModel<T>(
        _ method: String, modelId: String, _ request: () async throws -> T
    ) async throws -> T {
        do {
            return try await request()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw model(error, method: method, modelId: modelId)
        }
    }

    /// acpx's `maybeWrapSessionControlError`: an agent's error that looks like it does not
    /// support the control is `Agent rejected <method> <context>: <summary>. The adapter
    /// may not implement <method>, or the requested value is not supported.`; any other
    /// error stays as it was.
    static func wrap(_ error: Error, method: String, context: String) -> Error {
        guard let acp = TurnFailure.payload(of: error), looksUnsupported(acp) else { return error }
        return SessionControlError(
            message: "Agent rejected \(method) \(context): \(summary(acp)). "
                + "The adapter may not implement \(method), or the requested value is not supported.",
            acp: acp)
    }

    /// acpx's `throwSessionModelError`: wrapped as ``wrap(_:method:context:)`` wraps, or
    /// otherwise `Failed <method> for model "<id>": <summary>` — the agent's error by its
    /// summary, anything else by its message.
    static func model(_ error: Error, method: String, modelId: String) -> Error {
        let wrapped = wrap(error, method: method, context: "for model \"\(modelId)\"")
        if wrapped is SessionControlError { return wrapped }
        let acp = TurnFailure.payload(of: error)
        return SessionControlError(
            message: "Failed \(method) for model \"\(modelId)\": \(acp.map(summary) ?? TurnFailure.message(of: error))",
            acp: acp)
    }

    /// acpx's `isLikelySessionControlUnsupportedError`: method not found, invalid params,
    /// or an internal error whose details say invalid params.
    private static func looksUnsupported(_ acp: AcpErrorPayload) -> Bool {
        if acp.code == -32601 || acp.code == -32602 { return true }
        guard acp.code == -32603, let details = acp.data?["details"]?.stringValue else { return false }
        return details.lowercased().contains("invalid params")
    }

    /// acpx's `formatSessionControlAcpSummary`: the details when there are any, naming what
    /// the adapter reported, else its message; each with the code.
    static func summary(_ acp: AcpErrorPayload) -> String {
        let code = WireJSON.javaScriptString(for: acp.code)
        if let details = acp.data?["details"]?.stringValue?.javaScriptTrimmed, !details.isEmpty {
            return "\(details) (ACP \(code), adapter reported \"\(acp.message)\")"
        }
        return "\(acp.message) (ACP \(code))"
    }
}
