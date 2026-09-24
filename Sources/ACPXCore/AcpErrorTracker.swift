import Foundation

// acpx's `AcpErrorTracker` (`session/execution/runtime.ts`) and `extractAcpError`
// (`acp/error-shapes.ts`): which ACP error a failed turn is, and whether the stream
// already showed it. The CLI prints the stream; acpxd, which sees the wire, says how
// the turn failed.

/// An ACP error as acpx's `extractAcpError` finds one: `{code, message, data}` on the
/// value itself or nested under `error`, `acp` or `cause`, five levels down.
public struct AcpErrorPayload: Equatable, Sendable {
    public var code: Double
    public var message: String
    public var data: WireJSON?

    public init(code: Double, message: String, data: WireJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func extract(from value: WireJSON, depth: Int = 0) -> AcpErrorPayload? {
        guard depth <= 5, case .object = value else { return nil }
        if case .number(let code)? = value["code"], code.isFinite,
            let message = value["message"]?.stringValue, !message.isEmpty {
            return AcpErrorPayload(code: code, message: message, data: value["data"])
        }
        for key in ["error", "acp", "cause"] {
            if let nested = value[key], let found = extract(from: nested, depth: depth + 1) { return found }
        }
        return nil
    }

    /// acpx's `outboundAcpErrorMatches`: a failure is this error when its text is, or
    /// contains, the error's `data.details` (or else its message), case-insensitively.
    public func matches(failureText: String) -> Bool {
        let details = data?["details"]?.stringValue
        let candidate =
            details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? message
        let normalizedFailure = failureText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedFailure == normalizedCandidate || normalizedFailure.contains(normalizedCandidate)
    }
}

/// acpx's `AcpErrorTracker`: the errors the stream has shown. A failure that matches
/// one is already on screen, so nothing more is printed for it: the agent's latest
/// error response always counts; a refusal the client sent counts when the failure
/// says the same thing.
///
/// Each attempt at the prompt starts afresh (``reset()``), as acpx's does before it
/// checks and sends the prompt: an error from connecting the agent then does not stand
/// in for how the turn failed — not even for a prompt refused before it goes out.
public struct AcpErrorTracker: Sendable {
    private var latestInbound: AcpErrorPayload?
    private var outbound: [AcpErrorPayload] = []

    public init() {}

    /// A prompt attempt starts: nothing seen before it says how the attempt fails.
    public mutating func reset() {
        latestInbound = nil
        outbound.removeAll()
    }

    /// Note one message of the exchange: `inbound` from the agent, else from the client.
    public mutating func observe(_ message: WireJSON, inbound: Bool) {
        guard let error = AcpErrorPayload.extract(from: message) else { return }
        if inbound {
            latestInbound = error
        } else {
            outbound.append(error)
        }
    }

    public func match(failureText: String) -> AcpErrorPayload? {
        latestInbound ?? outbound.last { $0.matches(failureText: failureText) }
    }
}
