import ACPXCore
import Foundation
import SwiftACP
import SwiftMCP

/// What a flow's agent writes to stderr, for a caller under `--verbose`: acpx's client,
/// which runs in the flow's process, shows its agent's stderr there (`verbose`). Here the
/// agent runs in acpxd, so its stderr goes to the call that runs it — the session's
/// creation, then each of its turns — as ``AgentStderrEvent``s, in order. What it writes
/// between calls waits for the next one, the oldest dropped past ``waitingLimit``.
final class AgentStderrRelay: @unchecked Sendable {
    /// The most bytes that wait for a call.
    static let waitingLimit = 1 << 20
    /// The most chunks that wait for a slow caller while it is attached, the oldest dropped
    /// first: a chunk is at most 64 KiB, as the agent's stderr is read (#219 review).
    static let attachedChunkLimit = 256

    private let lock = NSLock()
    private var waiting: [Data] = []
    private var waitingBytes = 0
    private var feed: AsyncStream<Data>.Continuation?
    private var forwarder: Task<Void, Never>?

    /// What the agent's tap is given (``RawWireTap/onStderr(_:)``). It runs on the thread
    /// that reads the agent.
    var observer: RawWireTap.StderrObserver {
        { [weak self] bytes in self?.take(bytes) }
    }

    /// What the agent's tap is given for what the client notes of it (``RawWireTap/onLog(_:)``):
    /// each note goes to the caller as acpx's client writes it to the flow's stderr, `[acpx] <line>`,
    /// in order with what the agent writes.
    var logObserver: RawWireTap.LogObserver {
        { [weak self] line in self?.log(line) }
    }

    /// Send `line` to the caller as acpx writes its own diagnostics: `[acpx] <line>`.
    func log(_ line: String) {
        take(Data("[acpx] \(line)\n".utf8))
    }

    /// acpx's `logReconnectAttempt`: whether the agent `record` saved still runs, as a turn
    /// connects its session.
    func noteReconnect(of record: SessionRecord) {
        guard let pid = record.pid, pid != 0 else { return }
        if DaemonLock.isProcessAlive(Int32(pid)) {
            log("saved session pid \(pid) is running; reconnecting to saved ACP session")
        } else {
            log("saved session pid \(pid) is dead; respawning agent and attempting session reconnect")
        }
    }

    private func take(_ bytes: Data) {
        lock.withLock {
            if let feed {
                feed.yield(bytes)
                return
            }
            waiting.append(bytes)
            waitingBytes += bytes.count
            while waitingBytes > Self.waitingLimit, !waiting.isEmpty {
                waitingBytes -= waiting.removeFirst().count
            }
        }
    }

    /// Send what the agent writes to `caller` from now on, what waited first.
    func attach(to caller: CallerOutbox?, logger: String) {
        let (chunks, feed) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(Self.attachedChunkLimit))
        let forwarder = Task {
            for await chunk in chunks {
                await caller?.post(
                    LogMessage(level: .info, logger: logger, data: toJSONValue(AgentStderrEvent(chunk))))
            }
        }
        lock.withLock {
            // What waited goes out as one chunk, which the bound above never drops unseen.
            if !waiting.isEmpty { feed.yield(waiting.reduce(Data(), +)) }
            (waiting, waitingBytes) = ([], 0)
            self.feed?.finish()
            (self.feed, self.forwarder) = (feed, forwarder)
        }
    }

    /// Stop sending, once all that was sent has gone out: what the agent writes from now on
    /// waits for the next call.
    func detach() async {
        let forwarder: Task<Void, Never>? = lock.withLock {
            feed?.finish()
            defer { (feed, self.forwarder) = (nil, nil) }
            return self.forwarder
        }
        await forwarder?.value
    }
}

extension ACPXDaemonBackend {
    /// Under `--verbose`, where what the agent writes to stderr goes as a turn runs: the
    /// relay of a held agent, which has kept what it wrote since its session was made — or
    /// since a verbose call first asked for it — else a new one, kept with the held agent
    /// from now on, so what it writes between calls waits for the next. An agent the turn
    /// connects is given it (``CallerSettings/stderr``), and keeps it once held (#219 review).
    func stderrRelay(for recordId: String, verbose: Bool) -> AgentStderrRelay? {
        guard verbose else { return nil }
        let relay = live[recordId]?.stderr ?? AgentStderrRelay()
        live[recordId]?.stderr = relay
        live[recordId]?.agent.rawWire.onStderr(relay.observer)
        live[recordId]?.agent.rawWire.onLog(relay.logObserver)
        return relay
    }

    /// `body`, what the agent writes to stderr meanwhile sent through `relay` to the caller —
    /// all of it before this returns, however `body` ends.
    func relayingStderr<T>(
        _ relay: AgentStderrRelay?, logger: String, _ body: () async throws -> T
    ) async throws -> T {
        relay?.attach(to: ACPXDaemonBackend.caller, logger: logger)
        let outcome: Result<T, Error>
        do {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        await relay?.detach()
        return try outcome.get()
    }
}
