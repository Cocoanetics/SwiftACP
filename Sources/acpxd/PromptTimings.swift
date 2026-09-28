import Foundation
import SwiftACP

/// acpx's prompt timings under `--verbose`, as its runtime writes them for a turn it runs in the
/// caller's process — a flow's persistent turn (`emitConnectPerfMetric`, `emitPromptPerfMetric`
/// and `prompt.total`, `src/session/execution/runtime.ts`).
enum PromptTimings {
    /// `<name>=<milliseconds>ms`, the milliseconds to three places at most and written as
    /// JavaScript writes the number: acpx's `formatPerfMetric`.
    static func metric(_ name: String, milliseconds: Double) -> String {
        "\(name)=\(WireJSON.number((milliseconds * 1000).rounded() / 1000).stringified)ms"
    }

    /// The milliseconds since `start`: whole, as acpx's `Date.now()` differences are, or to the
    /// fraction, as its `process.hrtime` timer has them.
    static func milliseconds(since start: ContinuousClock.Instant, whole: Bool = false) -> Double {
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return whole ? milliseconds.rounded(.down) : milliseconds
    }
}

extension ACPXDaemonBackend {
    /// `body`, then — for a caller under `--verbose` — acpx's `prompt.total` however it ends: from
    /// when the turn took the session, `start`, to once its agent is let go.
    func timingTotal<T>(
        _ relay: AgentStderrRelay?, from start: ContinuousClock.Instant, _ body: () async throws -> T
    ) async rethrows -> T {
        defer {
            relay?.log(PromptTimings.metric("prompt.total", milliseconds: PromptTimings.milliseconds(since: start)))
        }
        return try await body()
    }
}
