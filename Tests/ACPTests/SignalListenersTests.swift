@testable import acpx
import Foundation
import Testing

/// Signals are heard as Node's one-off listeners hear them (#102): each listener present
/// hears the first, once. The signals stay caught while any listener is left — `compare`'s
/// own, while each run's comes and goes — and are left alone once none is.
struct SignalListenersTests {
    /// Stands in for the process's signals.
    final class FakeSignals: SignalListeners.Catching, @unchecked Sendable {
        private let lock = NSLock()
        private var heard: (@Sendable (String) -> Void)?
        private var started = 0
        private var stopped = 0

        func start(_ heard: @escaping @Sendable (String) -> Void) {
            lock.withLock {
                started += 1
                self.heard = heard
            }
        }

        func stop() {
            lock.withLock {
                stopped += 1
                heard = nil
            }
        }

        var caught: Bool { lock.withLock { heard != nil } }
        var counts: (started: Int, stopped: Int) { lock.withLock { (started, stopped) } }

        /// A signal comes.
        func signal(_ name: String = "SIGINT") {
            lock.withLock { heard }?(name)
        }
    }

    /// The names of the listeners that heard a signal.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func record(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }

    @Test func aListenerStaysWhileAnotherComesAndGoes() {
        let signals = FakeSignals()
        let listeners = SignalListeners(catching: signals)
        let heard = Heard()
        let outer = listeners.add { heard.record("outer") }
        let first = listeners.add { heard.record("first run") }
        listeners.remove(first)
        #expect(signals.caught)
        _ = listeners.add { heard.record("second run") }
        signals.signal()
        #expect(heard.all == ["outer", "second run"])
        // Each heard it once, and nothing listens any more.
        #expect(!signals.caught)
        signals.signal()
        #expect(heard.all == ["outer", "second run"])
        listeners.remove(outer)
        #expect(signals.counts == (started: 1, stopped: 1))
    }

    @Test func theSignalsAreLeftAloneOnceNoOneListens() {
        let signals = FakeSignals()
        let listeners = SignalListeners(catching: signals)
        let one = listeners.add {}
        let other = listeners.add {}
        listeners.remove(one)
        #expect(signals.caught)
        listeners.remove(other)
        #expect(!signals.caught)
        #expect(signals.counts == (started: 1, stopped: 1))
    }
}
