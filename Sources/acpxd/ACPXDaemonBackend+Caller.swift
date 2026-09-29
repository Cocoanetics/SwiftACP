import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

// Whom a turn tells how it goes: its caller, as acpx's owner tells the CLI that submitted the
// task — until a prompt queued without waiting is taken (#239).
extension ACPXDaemonBackend {
    /// A prompt queued without waiting (acpx's `--no-wait`), while it runs: set once the session's
    /// line has taken it, and the caller told then.
    @TaskLocal static var noWaitAdmission: NoWaitAdmission?

    /// Where a turn tells how it goes, in log notifications: its caller's outbox — none for a
    /// prompt queued without waiting once its line has it, as acpx's owner closes the connection
    /// of a task that does not wait and runs it with its output discarded
    /// (`DISCARD_OUTPUT_FORMATTER`).
    static var caller: CallerOutbox? {
        noWaitAdmission?.isTaken == true ? nil : CallerOutbox.current
    }

    /// A call, its client told what it sends through the call's outbox (``CallerOutbox``):
    /// without waiting for the client to read it, and all of it before the call's result —
    /// however the call ends. What waits for a stopped client holds the call, not the session
    /// the call's turn ran on, which the turn let go when it ended (openclaw/acpx#723).
    func servingCall<T>(
        isolation: isolated (any Actor)? = #isolation, _ work: () async throws -> T
    ) async throws -> T {
        guard let session = Session.current else { return try await work() }
        let outbox = CallerOutbox(session: session)
        let outcome: Result<T, Error>
        do {
            outcome = .success(try await CallerOutbox.$current.withValue(outbox) { try await work() })
        } catch {
            outcome = .failure(error)
        }
        await outbox.flush()
        return try outcome.get()
    }

    /// acpx's `--no-wait` (#239): `turn` runs as any queued prompt does, and this returns as soon
    /// as the session's line has taken it — begun at once, or waiting behind others — as acpx's
    /// CLI returns on the owner's `accepted`. The turn runs on, telling no one; a prompt refused
    /// before the line takes it fails the call as a refusal fails any prompt.
    func queuedWithoutWaiting(_ turn: @escaping @Sendable () async throws -> String) async throws -> String {
        let admission = NoWaitAdmission()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            admission.waits(continuation)
            Task {
                do {
                    _ = try await Self.$noWaitAdmission.withValue(admission) { try await turn() }
                    admission.admit()
                } catch {
                    admission.refuse(error)
                }
            }
        }
        return ""
    }

    /// Forwards what connecting an agent for a turn put on the wire to the MCP client
    /// the turn is for, before the turn's own messages — noting its errors on the way.
    static func forwardToClient(logger: String, errors: TurnErrorWatch? = nil) -> ConnectOutputHandler {
        let caller = Self.caller
        return { messages in
            errors?.observe(messages)
            for message in messages {
                caller?.post(LogMessage(level: .info, logger: logger, data: toJSONValue(message)))
            }
        }
    }
}

/// Whether the session's line has taken a prompt queued without waiting, and the caller waiting
/// to hear it — or why it was refused.
final class NoWaitAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var caller: CheckedContinuation<Void, Error>?
    private var taken = false

    /// Whether the line has it: nothing of the turn goes to its caller from then on.
    var isTaken: Bool { lock.withLock { taken } }

    func waits(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { caller = continuation }
    }

    /// The line has it: the caller hears so, once.
    func admit() {
        lock.withLock { () -> CheckedContinuation<Void, Error>? in
            taken = true
            defer { caller = nil }
            return caller
        }?.resume()
    }

    /// Refused before the line had it: the caller hears why. Nothing, once it had it.
    func refuse(_ error: Error) {
        lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { caller = nil }
            return caller
        }?.resume(throwing: error)
    }
}
