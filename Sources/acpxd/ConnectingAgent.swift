import Foundation
import SwiftACP

/// An agent being connected for a turn or a control, before the daemon holds it: what a
/// close past its grace puts down, as acpx's owner closes its client whether it has
/// connected yet or not. Its launch is called off, or, once launched, the agent is
/// closed — which fails whatever connecting was waiting for.
final class ConnectingAgent: @unchecked Sendable {
    private let lock = NSLock()
    private var launching: Task<ACPAgent, Error>?
    private var agent: ACPAgent?
    private var abandoned = false

    /// Launch the agent with `launch`, which a close can call off meanwhile — throwing
    /// `CancellationError` then, and closing an agent that came up all the same.
    func launch(_ launch: @escaping @Sendable () async throws -> ACPAgent) async throws -> ACPAgent {
        let task = Task { try await launch() }
        let calledOff = lock.withLock {
            launching = task
            return abandoned
        }
        if calledOff { task.cancel() }
        let agent = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        let held = lock.withLock {
            launching = nil
            if !abandoned { self.agent = agent }
            return !abandoned
        }
        guard held else {
            await agent.close()
            throw CancellationError()
        }
        return agent
    }

    /// Put it down: its launch called off, or the agent it launched closed.
    func abandon() async {
        let (task, agent) = lock.withLock {
            abandoned = true
            return (launching, self.agent)
        }
        task?.cancel()
        await agent?.close()
    }
}
