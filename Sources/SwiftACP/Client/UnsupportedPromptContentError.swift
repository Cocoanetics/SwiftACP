import Foundation

/// A prompt block the agent never advertised support for, refused before dispatch.
///
/// ACP gates `image`, `audio` and embedded `resource` blocks on
/// `promptCapabilities`; an agent that receives one it did not claim is free to
/// ignore it, so the refusal is the client's job. Mirrors npm acpx's
/// `UnsupportedPromptContentError`.
public struct UnsupportedPromptContentError: LocalizedError, Equatable {
    /// Which block in the prompt was refused.
    public let index: Int
    /// The `promptCapabilities` flag it needed — `image`, `audio` or `embeddedContext`.
    public let capability: String
    /// The agent's self-reported name, when it gave one on `initialize`.
    public let agent: String?

    public init(index: Int, capability: String, agent: String?) {
        self.index = index
        self.capability = capability
        self.agent = agent
    }

    public var errorDescription: String? {
        let who = agent.map { "\"\($0)\"" } ?? "this agent"
        return """
            prompt[\(index)] needs promptCapabilities.\(capability), which \(who) does not \
            advertise
            """
    }
}
