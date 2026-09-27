import Foundation

/// A chunk of what a flow's agent wrote to stderr, streamed to the caller as an MCP log
/// notification when it asks (``ACPXDaemon``'s `newSession` and `runPrompt` `verbose`):
/// acpx's client, which runs in the flow's process, shows its agent's stderr there under
/// `--verbose`. The bytes as they were, in base64, so a character split between two chunks
/// arrives whole.
public struct AgentStderrEvent: Codable, Sendable, Equatable {
    /// The chunk's bytes, in base64. Named apart from every other event's fields, so no
    /// event decodes as another.
    public var agentStderr: String

    public init(_ bytes: Data) {
        agentStderr = bytes.base64EncodedString()
    }

    /// The chunk's bytes; `nil` if they are not base64.
    public var bytes: Data? { Data(base64Encoded: agentStderr) }
}
