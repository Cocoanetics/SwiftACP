/// The signals the agent transport ends an agent with (``AgentProcessTransport``), by the numbers
/// POSIX gives them, and their names as Node reports them. Windows' C runtime has no `SIGKILL`,
/// and a Windows process ended with either is reported with the signal sent, as libuv reports it.
enum ProcessSignal {
    static let terminate: Int32 = 15
    static let kill: Int32 = 9

    /// Node's name for `signal`, for those a Windows process is ended with.
    static func name(_ signal: Int32) -> String {
        [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 9: "SIGKILL", 15: "SIGTERM"][signal] ?? ""
    }
}
