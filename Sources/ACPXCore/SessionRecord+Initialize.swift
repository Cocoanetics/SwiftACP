import Foundation
import JSONFoundation
import SwiftACP

extension SessionRecord {
    /// What the agent's `initialize` answered, as acpx records it when it creates the session and
    /// after each turn that succeeds (`savePromptSuccess`): its protocol version, and its
    /// capabilities as it `sent` them — every member, in its order (#119). Without them as sent —
    /// no wire tap read them — the capabilities decoded stand in.
    public mutating func applyInitialize(_ result: InitializeResponse, capabilitiesAsSent sent: WireJSON?) {
        protocolVersion = result.protocolVersion
        if let sent {
            agentCapabilities = sent.jsonValue
            agentCapabilitiesAsSent = sent
        } else {
            agentCapabilities = result.agentCapabilities.flatMap { try? JSONValue(encoding: $0) }
            agentCapabilitiesAsSent = nil
        }
    }

    /// ``applyInitialize(_:capabilitiesAsSent:)`` with what `agent` was answered.
    public mutating func applyInitialize(of agent: ACPAgent) async {
        let sent = await agent.connection.agentCapabilitiesAsSent
        applyInitialize(agent.initializeResult, capabilitiesAsSent: sent)
    }
}
