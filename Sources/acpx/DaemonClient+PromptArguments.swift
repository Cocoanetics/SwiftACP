import Foundation
import JSONFoundation
import SwiftACP
import SwiftMCP

// The arguments of a daemon turn, for calling ``ACPXDaemon``'s `runPrompt` untyped (see
// `runPrompt(on:…)`). Split from `DaemonClient.swift`.
extension DaemonClient {
    /// The arguments of ``ACPXDaemon``'s `runPrompt`, as its typed client sends them.
    static func promptArguments(
        sessionId: String, content: [JSONValue], wait: Bool, permissionMode: String, nonInteractivePermissions: String,
        streamWire: Bool, permissionPolicy: PermissionRules?, terminalOutputCeiling: Int, model: String?,
        sessionOptions: PromptSessionOptions?, limits: PromptLimits?
    ) throws -> JSONDictionary {
        var arguments: JSONDictionary = [
            "sessionId": .string(sessionId), "text": .string(""), "content": .array(content), "wait": .bool(wait),
            "permissionMode": .string(permissionMode), "nonInteractivePermissions": .string(nonInteractivePermissions),
            "streamWire": .bool(streamWire), "terminalOutputCeiling": .integer(terminalOutputCeiling)
        ]
        if let permissionPolicy {
            arguments["permissionPolicy"] = try MCPClientArgumentEncoder.encode(permissionPolicy)
        }
        if let model { arguments["model"] = .string(model) }
        if let sessionOptions { arguments["sessionOptions"] = try MCPClientArgumentEncoder.encode(sessionOptions) }
        if let limits { arguments["limits"] = try MCPClientArgumentEncoder.encode(limits) }
        return arguments
    }
}
