import Foundation
import SwiftACP

extension AcpErrorPayload {
    /// acpx's `isAcpAuthRequiredPayload`, by which its `resolveDetailCode` classes a
    /// failure `AUTH_REQUIRED`: the agent's `-32000` error, saying it needs credentials
    /// in its message, or in its data — `authRequired: true`, a `methodId`, or some
    /// `methods`.
    public var saysAuthRequired: Bool {
        guard code == -32000 else { return false }
        let lowered = message.lowercased()
        if Self.authRequiredPhrases.contains(where: { lowered.contains($0) }) { return true }
        guard let data, case .object = data else { return false }
        if case .bool(true)? = data["authRequired"] { return true }
        if let methodId = data["methodId"]?.stringValue, !methodId.javaScriptTrimmed.isEmpty { return true }
        if case .array(let methods)? = data["methods"], !methods.isEmpty { return true }
        return false
    }

    /// acpx's `isAuthRequiredMessage`.
    private static let authRequiredPhrases = [
        "auth required", "authentication required", "authorization required", "credential required",
        "credentials required", "token required", "login required"
    ]
}
