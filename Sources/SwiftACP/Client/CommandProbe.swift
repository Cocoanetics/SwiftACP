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
    /// stderr, whatever its exit — or `nil` when it could not start, ran past
    /// `timeoutMilliseconds`, or its caller was called off first. Whatever is left of its process
    /// group is ended then, as acpx's client retires a probe however it went — without holding up
    /// a caller called off (#263 review).
    static func output(
        of command: String, _ arguments: [String], cwd: String, environment: [String: String]?,
        timeoutMilliseconds: Int
    ) async -> String? {
        guard let child = try? ChildProcess.spawn(
            command: command, arguments: arguments, cwd: cwd, environment: environment, newSession: true)
        else { return nil }
        let capture = CommandProbeCapture()
        child.start(
            onChunk: { capture.append($0 == .stdout ? .stdout : .stderr, $1) }, onClose: { _ in capture.pipeClosed() },
            onExit: { _ in capture.exited() })
        let output = await withTaskCancellationHandler {
            await capture.output(within: timeoutMilliseconds)
        } onCancel: {
            capture.giveUp()
        }
        if Task.isCancelled {
            // Its caller has stopped waiting; the probe is ended all the same, bounded by its graces.
            Task.detached { await retire(child, capture: capture) }
        } else {
            await retire(child, capture: capture)
        }
        return output
    }

    /// acpx's `cleanupAgentProcess` for a probe: its group sent `SIGTERM` while any of it is
    /// left, then `SIGKILL` if the probe itself has not exited 1.5 s on, given 1 s more
    /// (`AGENT_CLOSE_TERM_GRACE_MS`, `AGENT_CLOSE_KILL_GRACE_MS`).
    private static func retire(_ child: ChildProcess, capture: CommandProbeCapture) async {
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
}
#endif
