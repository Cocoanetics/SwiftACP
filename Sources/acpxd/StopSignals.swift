#if Server
import Dispatch
import Foundation
import Logging
import ServiceLifecycle

/// The signals that stop acpxd, held from before it takes its lock until it has let it
/// go, as acpx's queue owner holds SIGINT, SIGTERM and SIGHUP from before it takes its
/// lease until the lease is released (0.19.3, #762). A signal no longer ends the daemon
/// where it stands, lock and all: one heard before the daemon can stop gracefully stops
/// it as soon as it can, and a signal after that asks for the same stop, which a second
/// one does not change.
final class StopSignals: @unchecked Sendable {
    /// SIGINT, SIGTERM and SIGHUP, as acpx's owner traps them.
    static let daemon: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var heard = false
    private var onStop: (@Sendable () -> Void)?

    /// Hold `signals` from now on: their default action no longer applies.
    init(_ signals: [Int32]) {
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.hear() }
            source.resume()
            sources.append(source)
        }
    }

    /// Call `stop` at each signal from now on — and at once for one already heard.
    func onSignal(_ stop: @escaping @Sendable () -> Void) {
        let pending: Bool = lock.withLock {
            onStop = stop
            return heard
        }
        if pending { stop() }
    }

    /// A signal came (or, in a test, stands in for one).
    func hear() {
        let stop: (@Sendable () -> Void)? = lock.withLock {
            heard = true
            return onStop
        }
        stop?()
    }

    /// Stop listening. The daemon listens for as long as it runs; tests let go.
    func cancel() {
        sources.forEach { $0.cancel() }
    }
}

extension ServiceGroup {
    /// Run `services` as acpxd runs them, stopping gracefully at each of `signals`: one
    /// heard before the group runs stops it as soon as it does, as asking a group to stop
    /// before then would end it before it began. `onRunning` is told when it runs.
    static func run(
        _ services: [ServiceGroupConfiguration.ServiceConfiguration], stoppingOn signals: StopSignals,
        logger: Logger, onRunning: @escaping @Sendable () -> Void = {}
    ) async throws {
        let (running, started) = AsyncStream<Void>.makeStream()
        let group = ServiceGroup(configuration: .init(
            services: services + [.init(service: Running(started: started))], logger: logger))
        let stopping = Task {
            for await _ in running { break }
            signals.onSignal { Task { await group.triggerGracefulShutdown() } }
            onRunning()
        }
        defer { stopping.cancel() }
        try await group.run()
    }
}

/// Says once that its group runs, then waits for the group to stop.
private struct Running: Service {
    let started: AsyncStream<Void>.Continuation

    func run() async throws {
        started.yield()
        started.finish()
        try await gracefulShutdown()
    }
}
#endif
