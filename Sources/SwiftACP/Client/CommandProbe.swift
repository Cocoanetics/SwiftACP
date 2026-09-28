#if os(macOS) || os(Linux)
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// acpx's command probe (`readAgentCommandOutput`, `captureCommandProbeOutput`): a short command
/// an agent's launch asks something of — `gemini --version`, `copilot --help` — run in the agent's
/// directory and environment, in a session of its own as Node's `detached` starts it (#248).
enum CommandProbe {
    /// What `command` wrote once it exited and both its pipes closed — stdout, a newline, then
    /// stderr, whatever its exit — or `nil` when it could not start or ran past
    /// `timeoutMilliseconds`. Whatever is left of its process group is ended then, as acpx's
    /// client retires a probe however it went.
    static func output(
        of command: String, _ arguments: [String], cwd: String, environment: [String: String]?,
        timeoutMilliseconds: Int
    ) async -> String? {
        guard let child = try? ChildProcess.spawn(
            command: command, arguments: arguments, cwd: cwd, environment: environment, newSession: true)
        else { return nil }
        let capture = Capture()
        child.start(
            onChunk: { capture.append($0, $1) }, onClose: { _ in capture.pipeClosed() },
            onExit: { _ in capture.exited() })
        let output = await capture.output(within: timeoutMilliseconds)
        await retire(child, capture: capture)
        return output
    }

    /// acpx's `cleanupAgentProcess` for a probe: its group sent `SIGTERM` while any of it is
    /// left, then `SIGKILL` if the probe itself has not exited 1.5 s on, given 1 s more
    /// (`AGENT_CLOSE_TERM_GRACE_MS`, `AGENT_CLOSE_KILL_GRACE_MS`).
    private static func retire(_ child: ChildProcess, capture: Capture) async {
        let group = -child.pid
        if kill(group, 0) == 0 {
            kill(group, SIGTERM)
            if await !capture.exit(within: 1_500) {
                kill(group, SIGKILL)
                _ = await capture.exit(within: 1_000)
            }
        }
        child.stopReading()
    }

    /// A probe's output as it comes, and its end: Node's `close` — exited, both pipes at their end.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout: [UInt8] = []
        private var stderr: [UInt8] = []
        private var closedPipes = 0
        private var hasExited = false
        private var settled = false
        private var closeWaiter: CheckedContinuation<String?, Never>?
        private var exitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

        func append(_ output: ChildProcess.Output, _ bytes: [UInt8]) {
            lock.withLock {
                guard !settled else { return }
                if output == .stdout { stdout += bytes } else { stderr += bytes }
            }
        }

        func pipeClosed() {
            lock.withLock { closedPipes += 1 }
            settleIfClosed()
        }

        func exited() {
            let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
                hasExited = true
                defer { exitWaiters = [:] }
                return Array(exitWaiters.values)
            }
            waiters.forEach { $0.resume(returning: true) }
            settleIfClosed()
        }

        private func settleIfClosed() {
            let written: ([UInt8], [UInt8])? = lock.withLock {
                hasExited && closedPipes == 2 ? (stdout, stderr) : nil
            }
            guard let (out, err) = written else { return }
            settle(String(decoding: out, as: UTF8.self) + "\n" + String(decoding: err, as: UTF8.self))
        }

        private func settle(_ output: String?) {
            let waiter: CheckedContinuation<String?, Never>? = lock.withLock {
                guard !settled else { return nil }
                settled = true
                defer { closeWaiter = nil }
                return closeWaiter
            }
            waiter?.resume(returning: output)
        }

        /// The output once the probe closed, or `nil` past `milliseconds`.
        func output(within milliseconds: Int) async -> String? {
            await withCheckedContinuation { continuation in
                let ready: String?? = lock.withLock {
                    guard !settled else { return .some(nil) }
                    closeWaiter = continuation
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                    self.settle(nil)
                }
            }
        }

        /// Whether the probe exits within `milliseconds`.
        func exit(within milliseconds: Int) async -> Bool {
            let key = UUID()
            return await withCheckedContinuation { continuation in
                let done: Bool = lock.withLock {
                    if hasExited { return true }
                    exitWaiters[key] = continuation
                    return false
                }
                if done {
                    continuation.resume(returning: true)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                    self.lock.withLock { self.exitWaiters.removeValue(forKey: key) }?.resume(returning: false)
                }
            }
        }
    }
}
#endif
