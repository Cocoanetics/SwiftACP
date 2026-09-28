import ACPXCore
import Foundation
import SwiftACP

// What a tool's failure tells the caller beyond its message, so the CLI reports it as acpx
// reports it where it arose (#171).
extension ACPXDaemonBackend {
    /// What `error` says of itself for acpx's output, as acpx's normalization reads it
    /// (`readOutputErrorMeta`, `extractAcpError`): its codes and origin, whether it may be
    /// retried, and the agent's error it is. `nil` when it says none of that.
    nonisolated func toolFailure(for error: Error) -> ToolFailure? {
        let meta = error as? OutputErrorMeta
        let failure = ToolFailure(
            outputCode: meta?.outputCode, detailCode: meta?.detailCode, origin: meta?.origin,
            retryable: meta?.retryable, acp: TurnFailure.payload(of: error)?.jsonValue)
        return failure.isEmpty ? nil : failure
    }
}

/// A control the session's owner could not carry out, as acpx's owner answers one
/// (`handleControlRequest`, `makeQueueOwnerErrorFromUnknown`) and its CLI reports the answer
/// (`queueConnectionErrorFromOwner`): normalized with the owner's defaults unless the failure
/// names its own — a runtime failure (`NO_SESSION` for a session the agent no longer knows),
/// detail code `QUEUE_CONTROL_REQUEST_FAILED`, origin `queue` — by its message, with the
/// agent's error it is.
struct OwnedControlFailure: LocalizedError, OutputErrorMeta, AcpErrorCarrier, ErrorWithCause {
    let message: String
    let outputCode: String?
    let detailCode: String?
    let origin: String?
    let retryable: Bool?
    let acp: AcpErrorPayload?
    let cause: Error?

    init(_ error: Error) {
        let meta = error as? OutputErrorMeta
        var outputCode = meta?.outputCode ?? "RUNTIME"
        if outputCode == "RUNTIME", ReconnectFallback.isResourceNotFound(error) { outputCode = "NO_SESSION" }
        self.outputCode = outputCode
        detailCode = meta?.detailCode ?? "QUEUE_CONTROL_REQUEST_FAILED"
        origin = meta?.origin ?? "queue"
        retryable = meta?.retryable
        acp = TurnFailure.payload(of: error)
        message = TurnFailure.message(of: error)
        cause = error
    }

    var errorDescription: String? { message }
}
