import Foundation

/// A launch its caller can put down before it is done, as acpx's `close()` puts down a client
/// still starting (#261). Once the launch has started its agent, putting it down ends the agent as
/// acpx's close ends it — its stdin, then signals — and the launch fails on that exit, as acpx's
/// `start` does: `ACP agent exited before initialize completed (…)`. Before then there is no agent
/// to end, and the caller calls the launch off itself.
///
/// ``ACPAgent`` launches run with one as ``current`` tell it of the agent they start.
public final class AgentLaunchClosing: @unchecked Sendable {
    /// The launch the current task runs, when its caller can put it down.
    @TaskLocal public static var current: AgentLaunchClosing?

    private let lock = NSLock()
    private var closed = false
    private var endAgent: (@Sendable () -> Void)?

    public init() {}

    /// Put the launch down: the agent it started is ended, and one it starts from now on as soon
    /// as it starts. Returns whether it had started one — whether the launch now fails on its own.
    @discardableResult
    public func close() -> Bool {
        let end: (@Sendable () -> Void)? = lock.withLock {
            closed = true
            return endAgent
        }
        end?()
        return end != nil
    }

    /// The launch has started its agent, which `end` ends — at once, if the launch was put down.
    func started(_ end: @escaping @Sendable () -> Void) {
        let putDown: Bool = lock.withLock {
            endAgent = end
            return closed
        }
        if putDown { end() }
    }
}
