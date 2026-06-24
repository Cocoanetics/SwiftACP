import Dispatch
import Foundation

/// Cooperative Ctrl-C handling, mirroring acpx: the first SIGINT runs
/// `onFirst` (send an ACP `session/cancel` so the agent stops gracefully); a
/// second SIGINT runs `onSecond` (force quit).
final class InterruptHandler: @unchecked Sendable {
    private let source: DispatchSourceSignal
    private let lock = NSLock()
    private var count = 0
    private let onFirst: @Sendable () -> Void
    private let onSecond: @Sendable () -> Void

    init(onFirst: @escaping @Sendable () -> Void, onSecond: @escaping @Sendable () -> Void) {
        self.onFirst = onFirst
        self.onSecond = onSecond
        // Ignore the default terminating behaviour so the dispatch source sees it.
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in self?.fire() }
        source.resume()
    }

    private func fire() {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        if current == 1 { onFirst() } else { onSecond() }
    }

    /// Stop handling SIGINT and restore the default disposition.
    func cancel() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
