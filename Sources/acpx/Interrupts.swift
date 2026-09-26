import ACPXCore
import Dispatch
import Foundation
import SwiftACP

/// acpx's `InterruptedError`: a run put down at a signal before it ended by itself. The
/// CLI exits `INTERRUPTED` (130) for it, saying nothing.
struct InterruptedError: Error {}

/// acpx's `withInterrupt`: SIGINT, SIGTERM and SIGHUP while a run goes. The first puts
/// the run down, which either ends by itself on what putting it down failed, or — told
/// so before anything is put down, so that nothing it does can end the run first — as
/// ``InterruptedError``. The signals are heard as Node's one-off listeners hear them
/// (``listen(_:)``): once one has come, and no one else listens, their default actions
/// are back, so another ends the process at once.
enum Interrupts {
    /// Stands in for the process's signals in a test: ``fire()`` is a signal arriving,
    /// which every listener present hears.
    final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var listeners: [Int: @Sendable (String) -> Void] = [:]
        private var nextId = 0

        func fire(_ signal: String = "SIGINT") {
            let heard: [@Sendable (String) -> Void] = lock.withLock {
                defer { listeners = [:] }
                return listeners.keys.sorted().compactMap { listeners[$0] }
            }
            for listener in heard { listener(signal) }
        }

        fileprivate func add(_ listener: @escaping @Sendable (String) -> Void) -> Int {
            lock.withLock {
                defer { nextId += 1 }
                listeners[nextId] = listener
                return nextId
            }
        }

        fileprivate func remove(_ id: Int) {
            _ = lock.withLock { listeners.removeValue(forKey: id) }
        }
    }

    /// The source a run under test is interrupted from, in place of the process's signals.
    @TaskLocal static var source: Source?

    /// A signal heard for a run before the run listened for one — `compare`'s, between
    /// admitting an agent and its run listening — which the run takes as its own. Node
    /// dispatches a signal only between turns of its event loop, so none comes between
    /// the two in acpx; here one can.
    @TaskLocal static var heardBefore: Heard?

    /// Whether a signal has come, as a listener records it.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var came = false
        private var name: String?

        func heard(_ signal: String = "SIGINT") {
            lock.withLock {
                came = true
                name = name ?? signal
            }
        }

        var happened: Bool { lock.withLock { came } }
        /// The signal that came first, if one did.
        var signal: String? { lock.withLock { name } }

        /// Record a signal, saying whether it is the first.
        func first() -> Bool {
            lock.withLock {
                defer { came = true }
                return !came
            }
        }
    }

    /// Hears the first of SIGINT, SIGTERM and SIGHUP after it was added, once — acpx's
    /// `process.once` listeners — until it is stopped.
    struct Listening {
        fileprivate let stopListening: () -> Void

        func stop() { stopListening() }
    }

    /// Call `heard` at the first signal from now on, unless stopped before: on the test's
    /// ``source`` if it has one, else on the process's signals, which others may be
    /// listening to meanwhile.
    static func listen(_ heard: @escaping @Sendable (_ signal: String) -> Void) -> Listening {
        if let source {
            let id = source.add(heard)
            return Listening { source.remove(id) }
        }
        let id = SignalListeners.shared.add(heard)
        return Listening { SignalListeners.shared.remove(id) }
    }

    /// Run `run`; at the first signal, `onInterrupt` puts it down. It calls the function
    /// it is given, before putting anything down, when the run is to end as
    /// ``InterruptedError`` rather than on what it waits for — acpx's close rejects the
    /// requests pending, and the run ends on that before the interrupt does. The run then
    /// no longer can, and ends so once `onInterrupt` is done, as acpx's rejects only once
    /// its `onInterrupt` has closed the client.
    static func withInterrupt<T: Sendable>(
        _ run: @escaping @Sendable () async throws -> T,
        onInterrupt: @escaping @Sendable (_ endInterrupted: @escaping @Sendable () -> Void) async -> Void
    ) async throws -> T {
        try await withInterrupt(run, onSignal: { _, endInterrupted in await onInterrupt(endInterrupted) })
    }

    /// ``withInterrupt(_:onInterrupt:)``, `onSignal` told which signal came — acpx's
    /// `onInterrupt(signal)`, which a flow forwards to the shell commands it runs.
    static func withInterrupt<T: Sendable>(
        _ run: @escaping @Sendable () async throws -> T,
        onSignal: @escaping @Sendable (
            _ signal: String, _ endInterrupted: @escaping @Sendable () -> Void
        ) async -> Void
    ) async throws -> T {
        let outcome = FirstOutcome<T>()
        // Heard once, whether by the listener, before it listened (``heardBefore``), or both.
        let once = Heard()
        let interrupt: @Sendable (String) -> Void = { signal in
            guard once.first() else { return }
            Task {
                await onSignal(signal) { outcome.reserve() }
                outcome.settleReserved(.failure(InterruptedError()))
            }
        }
        let listening = listen(interrupt)
        defer { listening.stop() }
        if let heard = heardBefore, heard.happened { interrupt(heard.signal ?? "SIGINT") }
        Task {
            do {
                outcome.settle(.success(try await run()))
            } catch {
                outcome.settle(.failure(error))
            }
        }
        return try await outcome.value()
    }
}

/// The process's SIGINT, SIGTERM and SIGHUP, as Node's one-off listeners hear them: every
/// listener present hears the first of them, once, and is gone. While any listens, the
/// signals reach only them; with none left, their default actions are back.
final class SignalListeners: @unchecked Sendable {
    static let shared = SignalListeners(catching: ProcessSignals())

    /// Where the signals come from: caught while there are listeners, left alone when not.
    protocol Catching: Sendable {
        func start(_ heard: @escaping @Sendable (_ signal: String) -> Void)
        func stop()
    }

    private let catching: Catching
    private let lock = NSLock()
    private var listeners: [Int: @Sendable (String) -> Void] = [:]
    private var nextId = 0
    private var caught = false

    init(catching: Catching) {
        self.catching = catching
    }

    func add(_ listener: @escaping @Sendable (_ signal: String) -> Void) -> Int {
        lock.withLock {
            defer { nextId += 1 }
            listeners[nextId] = listener
            if !caught {
                caught = true
                catching.start { [weak self] signal in self?.heard(signal) }
            }
            return nextId
        }
    }

    func add(_ listener: @escaping @Sendable () -> Void) -> Int {
        add { _ in listener() }
    }

    func remove(_ id: Int) {
        lock.withLock {
            guard listeners.removeValue(forKey: id) != nil, listeners.isEmpty else { return }
            release()
        }
    }

    /// A signal came: each listener hears it, once.
    func heard(_ signal: String) {
        let heard: [@Sendable (String) -> Void] = lock.withLock {
            defer {
                listeners = [:]
                release()
            }
            return listeners.keys.sorted().compactMap { listeners[$0] }
        }
        for listener in heard { listener(signal) }
    }

    /// Leave the signals to their default actions again. Called with `lock` held.
    private func release() {
        guard caught else { return }
        caught = false
        catching.stop()
    }
}

/// The process's own signals, caught through dispatch sources.
private final class ProcessSignals: SignalListeners.Catching, @unchecked Sendable {
    private static let signals = [SIGINT, SIGTERM, SIGHUP]
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []

    func start(_ heard: @escaping @Sendable (_ signal: String) -> Void) {
        lock.withLock {
            for number in Self.signals {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                let name = number == SIGINT ? "SIGINT" : number == SIGTERM ? "SIGTERM" : "SIGHUP"
                source.setEventHandler { heard(name) }
                sources.append(source)
                source.resume()
            }
        }
    }

    func stop() {
        lock.withLock {
            for source in sources { source.cancel() }
            sources = []
            for number in Self.signals { signal(number, SIG_DFL) }
        }
    }
}

/// The first of a run's outcome and its interrupt, handed to whoever waits for it. The
/// interrupt can take the outcome before it has one to give (``reserve()``).
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<T, Error>?
    private var reserved = false
    private var waiter: CheckedContinuation<T, Error>?

    func settle(_ result: Result<T, Error>) {
        settle(result, reservedFor: false)
    }

    /// Take the outcome for the interrupt, unless it is settled already.
    func reserve() {
        lock.withLock { if settled == nil { reserved = true } }
    }

    /// Settle the outcome the interrupt took, if it took it.
    func settleReserved(_ result: Result<T, Error>) {
        settle(result, reservedFor: true)
    }

    private func settle(_ result: Result<T, Error>, reservedFor interrupt: Bool) {
        let waiter: CheckedContinuation<T, Error>? = lock.withLock {
            guard settled == nil, reserved == interrupt else { return nil }
            settled = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<T, Error>? = lock.withLock {
                if let settled { return settled }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}

/// What putting a one-shot run down at a signal needs, as the run gets it — acpx's
/// `handleInterrupt` for `runOnce`: the prompt out is cancelled and given 2.5 s to settle
/// (`cancelActivePrompt`), then the agent is closed (`closeOwnedClient`) — or, still
/// starting, its launch is called off, and an agent that came up just then closed.
final class RunInterrupt: @unchecked Sendable {
    /// How long acpx waits for a prompt it cancels at an interrupt (`INTERRUPT_CANCEL_WAIT_MS`).
    static let cancelWaitMilliseconds = 2_500

    private let lock = NSLock()
    private var launching: Task<ACPAgent, Error>?
    private var agent: ACPAgent?
    private var sessionId: SessionId?
    private var interrupted = false

    /// Launch the agent with `launch`, which an interrupt calls off.
    func launch(_ launch: @escaping @Sendable () async throws -> ACPAgent) async throws -> ACPAgent {
        let task = Task { try await launch() }
        if lock.withLock({ launching = task; return interrupted }) { task.cancel() }
        let agent = try await task.value
        lock.withLock { self.agent = agent }
        return agent
    }

    /// The run's session is open.
    func opened(_ sessionId: SessionId) {
        lock.withLock { self.sessionId = sessionId }
    }

    /// Put the run down, as acpx's `handleInterrupt` does. The run ends by itself, as
    /// acpx's does before its interrupt, when it waits for something the close fails — a
    /// prompt still out, `session/new`, the model's request — or when the agent answered
    /// its prompt within the wait. Otherwise — nothing out, as in the pause before a
    /// retry, a prompt the agent failed, or the agent still starting — it ends
    /// interrupted (`endInterrupted`), before anything is put down.
    func putDown(endInterrupted: @Sendable () -> Void) async {
        var agent: ACPAgent?
        var sessionId: SessionId?
        var launching: Task<ACPAgent, Error>?
        lock.withLock {
            interrupted = true
            agent = self.agent
            sessionId = self.sessionId
            launching = self.launching
        }
        guard let agent else {
            // acpx closes the client it is starting, and the run fails on the agent's exit
            // (#142 for how that exit is recorded); here the launch is called off.
            endInterrupted()
            launching?.cancel()
            if let late = try? await launching?.value { await late.close() }
            return
        }
        let connection = agent.connection
        if let sessionId, await connection.hasPromptInFlight(sessionId: sessionId) {
            try? await connection.cancel(sessionId: sessionId)
            let answered = try? await withTimeout(milliseconds: Self.cancelWaitMilliseconds) {
                await connection.waitForPromptToSettle(sessionId: sessionId)
            }
            // Failed by the agent within the wait: the run goes on (to a retry's pause).
            if answered == .some(false) { endInterrupted() }
        } else if await !connection.hasRequestsOutstanding {
            endInterrupted()
        }
        await agent.close()
    }
}
