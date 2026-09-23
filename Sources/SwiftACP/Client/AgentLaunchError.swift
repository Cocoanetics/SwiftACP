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
    ///
    /// - Parameter agentCommand: the *resolved command line*, as configured — acpx names
    ///   the agent by that string, quoting included, not by a re-joined argv. Falls back
    ///   to the split launch only when the caller has nothing better.
    static func failure(for launch: ProcessLaunch, agentCommand: String? = nil)
        -> AgentLaunchError? {
        let command =
            agentCommand ?? ([launch.executable] + launch.arguments).joined(separator: " ")

        if let directory = launch.workingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                return AgentLaunchError(
                    agentCommand: command, workingDirectory: directory,
                    detailCode: AgentLaunchError.spawnENOENT, missingPath: directory)
            }
        }
        return executableFailure(for: launch, command: command)
    }

    #if os(Windows)
    /// Windows resolves an executable through rules this cannot faithfully reproduce:
    /// the variable is usually `Path` rather than `PATH`, entries are `;`-separated, and
    /// a bare name is matched against `PATHEXT` extensions before it names a file at
    /// all. Guessing would mean refusing launches that would have worked — far worse
    /// than the opaque spawn error this replaces — so the executable is left to the
    /// spawn. The working-directory check above still applies.
    private static func executableFailure(for launch: ProcessLaunch, command: String)
        -> AgentLaunchError? { nil }
    #else
    private static func executableFailure(for launch: ProcessLaunch, command: String)
        -> AgentLaunchError? {
        guard let resolved = resolvedExecutable(launch.executable, environment: launch.environment)
        else {
            // A file that is there but not executable failed on permissions, not on a
            // missing path: acpx reserves the qualified wording for the latter, so this
            // takes the bare message and no `AGENT_SPAWN_ENOENT`.
            if launch.executable.contains("/"),
                FileManager.default.fileExists(atPath: launch.executable) {
                return AgentLaunchError(
                    agentCommand: command, workingDirectory: launch.workingDirectory,
                    detailCode: nil)
            }
            return AgentLaunchError(
                agentCommand: command, workingDirectory: launch.workingDirectory,
                detailCode: AgentLaunchError.spawnENOENT, missingPath: launch.executable)
        }
        // "a required executable, *interpreter*, … was not found" — a script whose `#!`
        // names a missing interpreter is executable itself, yet the spawn still fails
        // ENOENT, so the interpreter is what the message should name.
        if let interpreter = missingInterpreter(of: resolved) {
            return AgentLaunchError(
                agentCommand: command, workingDirectory: launch.workingDirectory,
                detailCode: AgentLaunchError.spawnENOENT, missingPath: interpreter)
        }
        return nil
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

    /// The interpreter a `#!` line names, when that interpreter cannot be executed.
    /// `nil` for a binary, an unreadable file, or an interpreter that is present.
    private static func missingInterpreter(of executable: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: executable) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256), head.starts(with: Data("#!".utf8))
        else { return nil }
        let firstLine = String(decoding: head, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let interpreter = firstLine.dropFirst(2)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).first.map(String.init)
        guard let interpreter, !interpreter.isEmpty,
            !FileManager.default.isExecutableFile(atPath: interpreter)
        else { return nil }
        return interpreter
    }

    private static func path(in environment: [String: String]?) -> String {
        environment?["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    }
    #endif
}
