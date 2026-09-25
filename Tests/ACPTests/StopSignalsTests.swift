@testable import ACPXCore
@testable import acpxd
import Foundation
import Logging
import ServiceLifecycle
import Testing

/// acpxd's stop signals, held from before it takes its lock, as acpx 0.19.3's queue owner
/// holds SIGINT, SIGTERM and SIGHUP from before its lease (#762): a stop heard before the
/// daemon runs stops it gracefully as soon as it does, one while it runs stops it, and
/// either way it lets its lock go.
@Suite(.serialized) struct StopSignalsTests {
    /// The daemon run as acpxd runs it, with its lock, until `signals` stop it.
    private func runDaemon(
        stoppingOn signals: StopSignals, onRunning: @escaping @Sendable () -> Void = {}
    ) async throws -> DaemonLock {
        let lock = DaemonLock()
        #expect(try lock.acquire())
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false, lock: lock)
        try await withTimeout(milliseconds: 10_000) {
            try await ServiceGroup.run(
                [.init(
                    service: daemon, successTerminationBehavior: .gracefullyShutdownGroup,
                    failureTerminationBehavior: .gracefullyShutdownGroup)],
                stoppingOn: signals, logger: Logger(label: "test.acpxd"), onRunning: onRunning)
        }
        return lock
    }

    @Test func theDaemonStopsAtSIGINTSIGTERMAndSIGHUP() {
        #expect(StopSignals.daemon == [SIGINT, SIGTERM, SIGHUP])
    }

    @Test func aStopHeardBeforeTheDaemonRunsStopsItOnceItDoes() async throws {
        try await withIsolatedStore {
            let signals = StopSignals([])
            signals.hear()
            let lock = try await runDaemon(stoppingOn: signals)
            #expect(lock.currentHolder() == nil)
        }
    }

    @Test func aStopHeardWhileTheDaemonRunsStopsIt() async throws {
        try await withIsolatedStore {
            let signals = StopSignals([])
            let lock = try await runDaemon(stoppingOn: signals) { signals.hear() }
            #expect(lock.currentHolder() == nil)
        }
    }

    /// A signal reaches the stop — SIGWINCH here, whose default is to be ignored.
    @Test func aSignalReachesTheStop() async throws {
        let signals = StopSignals([SIGWINCH])
        defer { signals.cancel() }
        let (stops, stopping) = AsyncStream<Void>.makeStream()
        signals.onSignal { stopping.yield() }
        raise(SIGWINCH)
        try await withTimeout(milliseconds: 10_000) {
            var heard = stops.makeAsyncIterator()
            _ = await heard.next()
        }
    }
}
