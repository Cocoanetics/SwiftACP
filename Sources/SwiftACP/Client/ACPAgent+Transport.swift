import Foundation
import JSONFoundation
import JSONRPCWire

#if os(macOS) || os(Linux) || os(Windows)
import JSONRPCSubprocess

// Starting an agent's transport, and reading a launch that failed with it — split from
// `ACPAgent.swift` to keep that file inside the 500-line limit.
extension ACPAgent {
    /// The agent's transport: started and read as acpx's client does, on Windows too (#272). A
    /// launch its caller can put down (``AgentLaunchClosing``) is told of the agent it started,
    /// which putting it down ends as acpx's `close()` ends it (#261).
    static func startTransport(
        _ spec: ProcessLaunch, agentCommand: String, maxMessageBytes: Int?, tap: RawWireTap
    ) throws -> any JSONRPCMessageTransport {
        do {
            let transport = try AgentProcessTransport.start(
                spec, agentCommand: agentCommand, maxMessageBytes: maxMessageBytes, tap: tap)
            AgentLaunchClosing.current?.started { Task { await transport.terminate() } }
            return transport
        } catch let error as ChildProcess.SpawnError {
            // acpx's `AgentSpawnError`, qualified when a launch path is missing.
            throw AgentLaunchError(
                agentCommand: agentCommand, workingDirectory: spec.workingDirectory,
                detailCode: error.code == ENOENT ? AgentLaunchError.spawnENOENT : nil)
        }
    }

    /// acpx's `normalizeInitializeError`: a handshake that failed because the agent went
    /// — its connection closed, or it has exited within 100 ms — is
    /// ``AgentStartupError``, with its exit and the end of its stderr. A line too long
    /// stays itself, and so does anything else the agent answered.
    static func startupFailure(
        _ error: Error, of transport: AgentProcessTransport, agentCommand: String
    ) async -> Error {
        guard !(error is AcpMessageLimitError) else { return error }
        let closed = ACPAgentConnection.isConnectionClosed(error)
        let exited = await transport.waitForExit(timeout: .milliseconds(100))
        guard closed || exited else { return error }
        let exit = transport.lifecycle.lastExit
        return AgentStartupError(
            agentCommand: agentCommand, exitCode: exit?.exitCode, signal: exit?.signal,
            stderrSummary: transport.stderrSummary)
    }
}
#endif
