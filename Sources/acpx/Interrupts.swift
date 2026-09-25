import ACPXCore
import Dispatch
import Foundation
import SwiftACP

/// acpx's `InterruptedError`: a run put down at a signal before it ended by itself. The
/// CLI exits `INTERRUPTED` (130) for it, saying nothing.
struct InterruptedError: Error {}

/// acpx's `withInterrupt`: SIGINT, SIGTERM and SIGHUP while a run goes. The first puts
/// the run down; unless the run ended meanwhile — or putting it down failed what it
/// waited for, so that it ends by itself — it then ends as ``InterruptedError``. Once
/// one has come, the signals' default actions are back, so another ends the process at
/// once, as Node's one-off listeners leave it.
enum Interrupts {
    /// Stands in for the process's signals in a test: ``fire()`` is a signal arriving.
    final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        private var fired = false

        func fire() {
            let handler: (@Sendable () -> Void)? = lock.withLock {
                fired = true
                defer { self.handler = nil }
                return self.handler
            }
            handler?()
        }

        fileprivate func watch(_ handler: @escaping @Sendable () -> Void) {
            let already = lock.withLock {
                if !fired { self.handler = handler }
                return fired
            }
            if already { handler() }
        }

        fileprivate func stop() {
            lock.withLock { handler = nil }
        }
    }

    /// The source a run under test is interrupted from, in place of the process's signals.
    @TaskLocal static var source: Source?

    /// Run `run`; at the first signal, `onInterrupt` puts it down, and the run ends as
    /// ``InterruptedError`` unless it ended first — or `onInterrupt` says that it failed
    /// what the run waits for: acpx's close rejects the requests pending, and the run
    /// ends on that before the interrupt does.
    static func withInterrupt<T: Sendable>(
        _ run: @escaping @Sendable () async throws -> T, onInterrupt: @escaping @Sendable () async -> Bool
    ) async throws -> T {
        let outcome = FirstOutcome<T>()
        let interrupted: @Sendable () -> Void = {
            Task {
                if await onInterrupt() { return }
                outcome.settle(.failure(InterruptedError()))
            }
        }
        let stopWatching: () -> Void
        if let source {
            source.watch(interrupted)
            stopWatching = { source.stop() }
        } else {
            let watch = SignalWatch(onFirst: interrupted)
            stopWatching = { watch.stop() }
        }
        defer { stopWatching() }
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

/// The process's SIGINT, SIGTERM and SIGHUP, watched until the first of them — then
/// left to their default actions again.
private final class SignalWatch: @unchecked Sendable {
    private static let signals = [SIGINT, SIGTERM, SIGHUP]
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []

    init(onFirst: @escaping @Sendable () -> Void) {
        for number in Self.signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard self?.stop() == true else { return }
                onFirst()
            }
            sources.append(source)
            source.resume()
        }
    }

    /// Stop watching; returns whether it was still watching.
    @discardableResult
    func stop() -> Bool {
        let sources: [DispatchSourceSignal] = lock.withLock {
            defer { self.sources = [] }
            return self.sources
        }
        guard !sources.isEmpty else { return false }
        for source in sources { source.cancel() }
        for number in Self.signals { signal(number, SIG_DFL) }
        return true
    }
}

/// The first of a run's outcome and its interrupt, handed to whoever waits for it.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func settle(_ result: Result<T, Error>) {
        let waiter: CheckedContinuation<T, Error>? = lock.withLock {
            guard settled == nil else { return nil }
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

    /// Put the run down. Returns whether the run ends by itself, as acpx's does before its
    /// interrupt: a prompt was out, and either the agent answered it within the wait or it
    /// was still out, so that the close fails it. One the agent failed leaves the run to
    /// go on — into the pause before a retry, say.
    func putDown() async -> Bool {
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
            launching?.cancel()
            if let late = try? await launching?.value { await late.close() }
            return false
        }
        let connection = agent.connection
        var endsByItself = false
        if let sessionId, await connection.hasPromptInFlight(sessionId: sessionId) {
            try? await connection.cancel(sessionId: sessionId)
            do {
                let answered = try await withTimeout(milliseconds: Self.cancelWaitMilliseconds) {
                    await connection.waitForPromptToSettle(sessionId: sessionId)
                }
                endsByItself = answered == true
            } catch {
                endsByItself = true
            }
        }
        await agent.close()
        return endsByItself
    }
}
