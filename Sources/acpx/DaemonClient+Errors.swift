import ACPXCore
import Foundation
import SwiftACP

// The CLI's errors for what acpxd did with a request. Split from `DaemonClient.swift` to keep it
// inside the 500-line limit.
extension DaemonClient {
    /// A control the daemon ran for this CLI failed, for the reason in `message` — with what the
    /// daemon said of it beyond that (``ToolFailure``), which output reports as acpx reports the
    /// failure where it arose (#171).
    struct DaemonControlFailure: LocalizedError, OutputErrorMeta, AcpErrorCarrier, ErrorWithCause {
        let message: String
        var failure: ToolFailure?

        init(message: String, failure: ToolFailure? = nil) {
            self.message = message
            self.failure = failure
        }

        var errorDescription: String? { message }
        var outputCode: String? { failure?.outputCode }
        var detailCode: String? { failure?.detailCode }
        var origin: String? { failure?.origin }
        var retryable: Bool? { failure?.retryable }
        var acp: AcpErrorPayload? { failure?.acp.flatMap(AcpErrorPayload.init) }

        /// The agent's error the failure is, as the daemon had it: what looks for one finds it
        /// here, as it would in the error itself — whether the session is gone, say
        /// (`ReconnectFallback.isResourceNotFound`).
        var cause: Error? {
            guard let acp, let code = Int(exactly: acp.code) else { return nil }
            return JSONRPCErrorBody(code: code, message: acp.message, data: acp.data?.jsonValue)
        }
    }

    /// acpxd went away with a request it had: acpx's `QueueConnectionError` for a queue
    /// owner that disconnects once it has acknowledged one, whose outcome is unknown.
    struct OwnerDisconnected: LocalizedError, OutputErrorMeta {
        /// What the request still waited for: `prompt completion`, or `responding`.
        let waitingFor: String
        var errorDescription: String? { "Queue owner disconnected before \(waitingFor); outcome unknown" }
        var outputCode: String? { "RUNTIME" }
        var detailCode: String? { "QUEUE_DISCONNECTED_BEFORE_COMPLETION" }
        var origin: String? { "queue" }
        var retryable: Bool? { false }
    }
}
