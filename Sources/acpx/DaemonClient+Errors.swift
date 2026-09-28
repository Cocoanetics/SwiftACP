import ACPXCore
import Foundation

// The CLI's errors for what acpxd did with a request. Split from `DaemonClient.swift` to keep it
// inside the 500-line limit.
extension DaemonClient {
    /// A control the daemon ran for this CLI failed, for the reason in `message`.
    struct DaemonControlFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
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
