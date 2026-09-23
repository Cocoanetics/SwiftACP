import Foundation

/// Why an agent adapter could not be launched.
///
/// Without this a missing binary surfaces as whatever the subprocess layer throws —
/// "The operation couldn't be completed. (Subprocess.SubprocessError error 1.)" — naming
/// neither the command nor anything to check. A faithful port of acpx's
/// `AgentSpawnError` (0.14.0, qualified in 0.19.1): the message and the additive
/// `AGENT_SPAWN_ENOENT` detail code are acpx's, verbatim.
///
/// acpx classifies the failure from the spawn error itself (`spawnEnoent`). Swift's
/// equivalent signal, `SubprocessError.Code.executableNotFound`, would mean importing
/// swift-subprocess directly into this target and pinning it separately from
/// JSONFoundation's, so the same condition is established before the spawn instead —
/// see ``AgentLaunchPreflight``. The condition and the resulting error are the same;
/// only where it is noticed differs.
public struct AgentLaunchError: Error, LocalizedError, Sendable {
    /// The command line the adapter was to be launched with.
    public let agentCommand: String
    /// The working directory it was to run in.
    public let workingDirectory: String?
    /// `AGENT_SPAWN_ENOENT` when a launch path itself could not be found, matching
    /// acpx's additive detail code; `nil` for any other spawn failure.
    public let detailCode: String?
    /// The launch path that was missing. acpx's message does not name it — kept here so
    /// a caller can, without diverging from the wording on the wire.
    public let missingPath: String?

    public init(
        agentCommand: String, workingDirectory: String?, detailCode: String?,
        missingPath: String? = nil
    ) {
        self.agentCommand = agentCommand
        self.workingDirectory = workingDirectory
        self.detailCode = detailCode
        self.missingPath = missingPath
    }

    /// acpx's `AgentSpawnError` message, verbatim: qualified when the failure is a
    /// launch path that does not exist, bare otherwise.
    public var errorDescription: String? {
        guard detailCode == AgentLaunchError.spawnENOENT else {
            return "Failed to spawn agent command: \(agentCommand)"
        }
        return "Failed to spawn agent command: \(agentCommand). The agent process could not"
            + " start because a required executable, interpreter, working directory, or other"
            + " launch path was not found. Check the command, effective PATH, and working"
            + " directory, or verify the custom agent's configured argv."
    }

    /// acpx's detail code for a launch path that does not exist.
    public static let spawnENOENT = "AGENT_SPAWN_ENOENT"
}

/// Checks an agent launch before paying for a spawn, so the failure names its cause
/// instead of surfacing as an opaque subprocess error.
enum AgentLaunchPreflight {
    /// The error to throw instead of spawning, or `nil` when the launch looks viable.
    static func failure(for launch: ProcessLaunch) -> AgentLaunchError? {
        let command = ([launch.executable] + launch.arguments).joined(separator: " ")
        let fileManager = FileManager.default

        if let directory = launch.workingDirectory {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                return AgentLaunchError(
                    agentCommand: command, workingDirectory: directory,
                    detailCode: AgentLaunchError.spawnENOENT, missingPath: directory)
            }
        }

        guard resolvedExecutable(launch.executable, environment: launch.environment) == nil else {
            return nil
        }
        return AgentLaunchError(
            agentCommand: command, workingDirectory: launch.workingDirectory,
            detailCode: AgentLaunchError.spawnENOENT, missingPath: launch.executable)
    }

    /// The path the child would actually execute, or `nil` when nothing matches. A name
    /// without a separator is looked up on the child's own `PATH`, which is what the
    /// spawn will use — not this process's.
    private static func resolvedExecutable(
        _ executable: String, environment: [String: String]?
    ) -> String? {
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }
        for directory in path(in: environment).split(separator: ":") {
            let candidate = String(directory) + "/" + executable
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func path(in environment: [String: String]?) -> String {
        environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    }
}
