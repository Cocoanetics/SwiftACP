import Foundation
import JSONFoundation
import SwiftACP

/// The result of the `session/prompt` response as it crossed the wire: where acpx's
/// quiet formatter reads a turn's `usage` and `cost` (`flushMetadata`), in whatever
/// shape and spelling the agent sent them. The first response carrying a `stopReason`
/// is the one, as acpx's `parsePromptStopReason` finds it.
public final class PromptResultCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: WireJSON?

    public init() {}

    /// Look at a message as it crossed the wire. Returns whether it is the prompt's
    /// result, arrived: the prompt is answered.
    @discardableResult
    public func observe(_ direction: JSONRPCPeer.WireDirection, _ body: Data) -> Bool {
        guard direction == .inbound, let message = WireJSON(parsing: body), !message.hasMember("method"),
              let result = message["result"], result["stopReason"]?.stringValue != nil
        else { return false }
        return lock.withLock {
            guard captured == nil else { return false }
            captured = result
            return true
        }
    }

    /// The prompt's result, once it has arrived.
    public var result: WireJSON? { lock.withLock { captured } }

    /// The result's `usage` and `cost`, as the agent sent them, for a client elsewhere.
    public var usage: JSONValue? { result?["usage"]?.jsonValue }
    public var cost: JSONValue? { result?["cost"]?.jsonValue }
}
