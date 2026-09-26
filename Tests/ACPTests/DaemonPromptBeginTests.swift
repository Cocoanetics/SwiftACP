@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// A prompt begins as acpx's queue owner begins the prompt task it takes (#173,
/// `runPromptTurn`): at once, unless another prompt of the session runs or waits before it
/// — then once those are over. Begun, it waits for the controls that hold the session, and
/// meanwhile a control sent is its, run on its agent once it goes out, and so is a cancel.
extension DaemonToolsTests {
    /// The signals of a session whose agent holds each `session/set_mode` until `gate`
    /// exists, having signalled `modeSent`, and signals `ready` as each prompt arrives.
    struct GatedModeAgent {
        let ready: URL
        let modeSent: URL
        let gate: URL

        var environment: String {
            "RETRY_AGENT_READY='\(ready.path)' RETRY_AGENT_SET_MODE_GATE='\(gate.path)' "
                + "RETRY_AGENT_SET_MODE_SENT='\(modeSent.path)' "
        }

        func openGate() {
            FileManager.default.createFile(atPath: gate.path, contents: nil)
        }
    }

    /// A session held by `daemon` as acpx's queue owner holds one — a first prompt, which its
    /// agent answers only once cancelled, cancelled — then an idle control that holds it, its
    /// request with the agent until `agent`'s gate opens; and a prompt behind that control,
    /// begun, which the agent answers only once cancelled. Returns the control and the prompt.
    private func promptBehindAnIdleControl(
        _ daemon: ACPXDaemonBackend, _ session: RetrySession, _ agent: GatedModeAgent, client: CallingClient
    ) async throws -> (idle: Task<SessionControlResult, Error>, prompt: Task<String, Error>) {
        let first = Task {
            try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
        }
        try await signalled(agent.ready)
        _ = try await daemon.cancelSession(sessionId: session.id)
        _ = try await withTimeout(milliseconds: 10_000) { try await first.value }

        let idle = Task { try await daemon.setMode(sessionId: session.id, modeId: "plan") }
        try await signalled(agent.modeSent)
        let (queued, queuing) = AsyncStream<Void>.makeStream()
        await daemon.turnQueue.setOnQueued { _ in queuing.yield() }
        let prompt = Task {
            try await limitedPrompt(
                daemon, session.id, limits: PromptLimits(ttlMs: 0), streamWire: true, client: client)
        }
        try await nextEvent(queued)
        await daemon.turnQueue.setOnQueued(nil)
        return (idle, prompt)
    }

    /// How many prompts the session's journal holds.
    private func promptsJournaled(_ id: String) throws -> Int {
        try String(contentsOf: ACPXPaths.sessionStreamPath(id), encoding: .utf8)
            .components(separatedBy: "\"session/prompt\"").count - 1
    }

    /// A control sent while a prompt waits behind an idle control runs during the prompt: on
    /// its agent, once it has gone out, and not once it is over.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlWhileAPromptWaitsBehindAnIdleControlRunsDuringThePrompt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = GatedModeAgent(
            ready: try fifo("ready", in: directory), modeSent: try fifo("mode-sent", in: directory),
            gate: directory.appendingPathComponent("gate"))
        defer { agent.openGate() }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: agent.environment)
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let client = CallingClient()
            let (idle, prompt) = try await promptBehindAnIdleControl(daemon, session, agent, client: client)

            let (taken, taking) = AsyncStream<Void>.makeStream()
            await daemon.setControlTakenHook { _ in taking.yield() }
            let control = Task {
                try await daemon.setConfigOption(sessionId: session.id, configId: "effort", value: "high")
            }
            try await nextEvent(taken)

            // The idle control ends, the prompt goes out, and the control runs as it runs on.
            agent.openGate()
            _ = try await withTimeout(milliseconds: 10_000) { try await idle.value }
            try await signalled(agent.ready)
            let result = try await withTimeout(milliseconds: 10_000) { try await control.value }
            #expect(!result.resumed)
            #expect(await daemon.turnQueue.isBusy(session.id), "the prompt runs on")

            _ = try await daemon.cancelSession(sessionId: session.id)
            _ = try await withTimeout(milliseconds: 10_000) { try await prompt.value }
            // Its exchange is the prompt's, after the prompt's own.
            let wire = client.wireKinds
            let prompted = try #require(wire.firstIndex(of: "wire:outbound:session/prompt"))
            let controlled = try #require(wire.firstIndex(of: "wire:outbound:session/set_config_option"), "\(wire)")
            #expect(controlled > prompted, "\(wire)")
            await daemon.releaseAll()
        }
    }

    /// A cancel while a prompt waits behind an idle control is the prompt's: once the prompt
    /// holds the session, it ends cancelled, nothing sent and nothing kept, as acpx's does —
    /// and a control waiting on it fails as it would on any prompt that never went out.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aCancelWhileAPromptWaitsBehindAnIdleControlEndsItUnsent() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = GatedModeAgent(
            ready: try fifo("ready", in: directory), modeSent: try fifo("mode-sent", in: directory),
            gate: directory.appendingPathComponent("gate"))
        defer { agent.openGate() }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: agent.environment)
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let client = CallingClient()
            let (idle, prompt) = try await promptBehindAnIdleControl(daemon, session, agent, client: client)
            let messages = try #require(SessionStore.loadRecord(session.id)).messages.count
            let prompts = try promptsJournaled(session.id)

            #expect(try await daemon.cancelSession(sessionId: session.id))
            let (taken, taking) = AsyncStream<Void>.makeStream()
            await daemon.setControlTakenHook { _ in taking.yield() }
            let control = Task {
                try await daemon.setConfigOption(sessionId: session.id, configId: "effort", value: "high")
            }
            try await nextEvent(taken)

            agent.openGate()
            _ = try await withTimeout(milliseconds: 10_000) { try await idle.value }
            #expect(try await withTimeout(milliseconds: 10_000) { try await prompt.value } == "")
            await #expect(throws: PromptEndedBeforeControls.self) {
                _ = try await withTimeout(milliseconds: 10_000) { try await control.value }
            }
            // Only the first prompt reached the agent; the record and journal kept nothing of
            // this one, whose end the client heard with nothing to mark it done.
            #expect(session.prompts == 1)
            #expect(try #require(SessionStore.loadRecord(session.id)).messages.count == messages)
            #expect(try promptsJournaled(session.id) == prompts)
            let ended = client.logs.compactMap { try? $0.decoded(TurnEndedEvent.self) }
            #expect(ended.map(\.stopReason) == ["cancelled"])
            #expect(ended.first?.unanswered == true)
            await daemon.releaseAll()
        }
    }

    /// A control sent as a prompt's turn is over — its controls sealed — while another prompt
    /// waits to begin runs before that prompt goes out, as acpx's owner runs it before it
    /// takes the next prompt task.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aControlAsAPromptEndsRunsBeforeThePromptWaitingToBegin() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' ")
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let first = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let second = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await nextEvent(waits)

            // Once the first prompt's controls are sealed, a control is sent, and waits for
            // the session.
            let (controlQueued, controlQueuing) = AsyncStream<Void>.makeStream()
            await daemon.turnQueue.setOnQueued { _ in controlQueuing.yield() }
            let sent = SentControl()
            await daemon.setControlsSealed { _ in
                guard sent.first() else { return }
                sent.task = Task { try await daemon.setMode(sessionId: session.id, modeId: "plan") }
                try? await nextEvent(controlQueued)
            }
            await daemon.setPromptGoingOut { _ in
                sent.modeAsThePromptWentOut = SessionStore.loadRecord(session.id)?.acpx?.desiredModeId
            }
            _ = try await daemon.cancelSession(sessionId: session.id)
            _ = try await withTimeout(milliseconds: 10_000) { try await first.value }
            try await signalled(ready)
            #expect(sent.modeAsThePromptWentOut == "plan", "the control ran before the second prompt")

            _ = try await daemon.cancelSession(sessionId: session.id)
            _ = try await withTimeout(milliseconds: 10_000) { try await second.value }
            let control = try #require(sent.task)
            _ = try await withTimeout(milliseconds: 10_000) { try await control.value }
            await daemon.turnQueue.setOnQueued(nil)
            await daemon.releaseAll()
        }
    }

    /// A prompt over without ever holding the session — its caller gone while it waited —
    /// has the session's owner wait for its next prompt, as acpx's owner does after any task
    /// it took: its wait may have run out meanwhile, and given way to the prompt.
    @Test func aPromptOverWithoutHoldingTheSessionHasTheOwnerWaitForTheNext() async throws {
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        await daemon.holdAsAnOwner("owned", ttlMilliseconds: 60_000)
        let begun = try await daemon.beginPrompt("owned", wait: true)
        await daemon.promptEnded("owned", begun, heldTheSlot: false).value
        #expect(await daemon.ownerWaitsForItsNextPrompt("owned"))
        await daemon.forgetOwner("owned")
    }

    /// Prompts begin one at a time, in the order they came, as acpx's queue owner takes its
    /// prompt tasks — the next in the same step the one before ends, its turn the session's
    /// before it even resumes, as nothing comes between acpx's tasks (Codex review on #196).
    /// One waiting to begin holds nothing of the session meanwhile.
    @Test func promptsBeginOneAtATimeInTheOrderTheyCame() async throws {
        // Bounded, so that a line that never moves fails rather than hangs.
        try await withTimeout(milliseconds: 10_000) {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let first = try await daemon.beginPrompt("s", wait: true)
            let second = Task { try await daemon.beginPrompt("s", wait: true) }
            try await nextEvent(waits)
            let third = Task { try await daemon.beginPrompt("s", wait: true) }
            try await nextEvent(waits)
            try await daemon.turnQueue.acquire("s", wait: false)
            await daemon.turnQueue.release("s")

            let afterFirst = await daemon.endPromptAndLook("s", first)
            let secondBegun = try await second.value
            #expect(afterFirst == secondBegun.control.id)
            let afterSecond = await daemon.endPromptAndLook("s", secondBegun)
            let thirdBegun = try await third.value
            #expect(afterSecond == thirdBegun.control.id)
            #expect(await daemon.endPromptAndLook("s", thirdBegun) == nil)
            _ = try await daemon.beginPrompt("s", wait: false)
        }
    }

    /// A prompt that will not wait is busy while anything holds the session — the slot, or a
    /// prompt begun — and otherwise begins holding the slot.
    @Test func aPromptThatWillNotWaitIsBusyWhileAnythingHoldsTheSession() async throws {
        // Bounded, so that a line that never moves fails rather than hangs.
        try await withTimeout(milliseconds: 10_000) {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            try await daemon.turnQueue.acquire("s", wait: true)
            await #expect(throws: DaemonError.self) { try await daemon.beginPrompt("s", wait: false) }
            await daemon.turnQueue.release("s")
            let begun = try await daemon.beginPrompt("s", wait: true)
            await #expect(throws: DaemonError.self) { try await daemon.beginPrompt("s", wait: false) }
            await daemon.promptEnded("s", begun, heldTheSlot: false).value

            let alone = try await daemon.beginPrompt("s", wait: false)
            await #expect(throws: DaemonError.self) { try await daemon.turnQueue.acquire("s", wait: false) }
            await #expect(throws: DaemonError.self) { try await daemon.beginPrompt("s", wait: false) }
            await daemon.promptEnded("s", alone, heldTheSlot: true).value
            #expect(await !daemon.turnQueue.isBusy("s"))
        }
    }

    /// A prompt called off before it begins leaves the line: none begins in its place.
    @Test func aPromptCalledOffBeforeItBeginsLeavesTheLine() async throws {
        // Bounded, so that a line that never moves fails rather than hangs.
        try await withTimeout(milliseconds: 10_000) {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let first = try await daemon.beginPrompt("s", wait: true)
            let calledOff = Task { try await daemon.beginPrompt("s", wait: true) }
            try await nextEvent(waits)
            calledOff.cancel()
            await #expect(throws: CancellationError.self) { try await calledOff.value }

            #expect(await daemon.endPromptAndLook("s", first) == nil)
            _ = try await daemon.beginPrompt("s", wait: false)
        }
    }

    /// A prompt called off as it is handed its turn ends there, handing the line on, rather
    /// than going on to the agent (Codex review on #196).
    @Test func aPromptCalledOffAsItBeginsEndsThere() async throws {
        // Bounded, so that a line that never moves fails rather than hangs.
        try await withTimeout(milliseconds: 10_000) {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let first = try await daemon.beginPrompt("s", wait: true)
            let second = Task { try await daemon.beginPrompt("s", wait: true) }
            try await nextEvent(waits)
            await daemon.endPrompt("s", first, thenCancel: second)
            await #expect(throws: CancellationError.self) { _ = try await second.value }
            #expect(await daemon.turnIsTheSessions("s") == false)
            _ = try await daemon.beginPrompt("s", wait: false)
        }
    }

    /// A prompt called off before it holds the session sends nothing and keeps nothing, however
    /// free the session is.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptCalledOffBeforeItHoldsTheSessionSendsNothing() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let calledOff = Task { () -> String in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await limitedPrompt(
                    daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            await #expect(throws: CancellationError.self) { _ = try await calledOff.value }
            #expect(session.prompts == 0)
            #expect(try #require(SessionStore.loadRecord(session.id)).messages.isEmpty)
            #expect(await !daemon.turnQueue.isBusy(session.id))
            await daemon.releaseAll()
        }
    }

    /// A close — or a release, for `sessions new` — refuses the prompts waiting in line behind
    /// the one running, none of them sent, as acpx's owner refuses its pending tasks as it shuts
    /// down (`beginShutdown`); the client hears it as acpx's CLI does (Codex review on #196).
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)), arguments: ["close", "release"])
    func shuttingASessionDownRefusesThePromptsInLine(how: String) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = try fifo("ready", in: directory)
        try await withIsolatedStore {
            let session = try await retrySession(in: directory, environment: "RETRY_AGENT_READY='\(ready.path)' ")
            try session.set("stall-prompt")
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let running = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: CallingClient())
            }
            try await signalled(ready)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let client = CallingClient()
            let inLine = Task {
                try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: client)
            }
            try await nextEvent(waits)

            if how == "close" {
                #expect(try await daemon.closeSession(sessionId: session.id))
            } else {
                #expect(try await daemon.releaseSession(sessionId: session.id))
            }
            await #expect(throws: QueueOwnerShuttingDown(inLine: true)) {
                _ = try await withTimeout(milliseconds: 10_000) { try await inLine.value }
            }
            let failure = try #require(client.failure)
            #expect(failure.message == "Queue owner shutting down before prompt execution")
            #expect(failure.detailCode == "QUEUE_OWNER_SHUTTING_DOWN")
            #expect(failure.origin == "queue" && failure.retryable == true)
            _ = try? await withTimeout(milliseconds: 10_000) { try await running.value }
            #expect(session.prompts == 1, "the prompt in line never went out")
            await daemon.releaseAll()
        }
    }

    /// A daemon that is stopping takes no prompt, as acpx's owner takes no task once it shuts
    /// down (`enqueue`): nothing is sent, and nothing kept.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aStoppingDaemonTakesNoPrompt() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let session = try await retrySession(in: directory)
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            await daemon.releaseAll()
            let client = CallingClient()
            await #expect(throws: QueueOwnerShuttingDown(inLine: false)) {
                _ = try await limitedPrompt(daemon, session.id, limits: PromptLimits(ttlMs: 0), client: client)
            }
            #expect(client.failure?.message == "Queue owner is shutting down")
            #expect(session.prompts == 0)
            #expect(try #require(SessionStore.loadRecord(session.id)).messages.isEmpty)
        }
    }

    /// The control a test sends once a turn's controls are sealed, and what it saw.
    private final class SentControl: @unchecked Sendable {
        private let lock = NSLock()
        private var sent = false
        private var control: Task<SessionControlResult, Error>?
        private var mode: String??

        /// Whether this is the first call.
        func first() -> Bool {
            lock.withLock {
                defer { sent = true }
                return !sent
            }
        }

        var task: Task<SessionControlResult, Error>? {
            get { lock.withLock { control } }
            set { lock.withLock { control = newValue } }
        }

        /// The session's mode as the next prompt went out: `nil` until one did.
        var modeAsThePromptWentOut: String? {
            get { lock.withLock { mode ?? nil } }
            set { lock.withLock { mode = mode ?? .some(newValue) } }
        }
    }
}

/// Wait for `stream`'s next event — bounded, so that one that never comes fails the test
/// rather than hangs it.
func nextEvent(_ stream: AsyncStream<Void>) async throws {
    try await withTimeout(milliseconds: 10_000) {
        var waiting = stream.makeAsyncIterator()
        _ = await waiting.next()
    }
}

extension ACPXDaemonBackend {
    func setControlsSealed(_ hook: (@Sendable (_ recordId: String) async -> Void)?) {
        controlsSealed = hook
    }

    /// Hold `recordId` as acpx's queue owner holds a session, not yet waiting for a prompt.
    func holdAsAnOwner(_ recordId: String, ttlMilliseconds: Int) {
        owners[recordId] = SessionOwner(ttlMilliseconds: ttlMilliseconds)
    }

    func ownerWaitsForItsNextPrompt(_ recordId: String) -> Bool {
        owners[recordId]?.idle != nil
    }

    func setPromptWaits(_ hook: (@Sendable (_ recordId: String) -> Void)?) {
        promptWaits = hook
    }

    /// End `begun`, and call `next` off in that same step, as it is handed its turn.
    func endPrompt(_ recordId: String, _ begun: BegunPrompt, thenCancel next: Task<BegunPrompt, Error>) {
        promptEnded(recordId, begun, heldTheSlot: false)
        next.cancel()
    }

    func turnIsTheSessions(_ recordId: String) -> Bool {
        turns[recordId] != nil
    }

    /// End `begun`, and say whose turn the session's is in that same step.
    func endPromptAndLook(_ recordId: String, _ begun: BegunPrompt) -> UUID? {
        promptEnded(recordId, begun, heldTheSlot: false)
        return turns[recordId]?.id
    }
}
