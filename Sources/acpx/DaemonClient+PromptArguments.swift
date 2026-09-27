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
        permissionPolicy: PermissionRules?, terminalOutputCeiling: Int, model: String?,
        sessionOptions: PromptSessionOptions?, limits: PromptLimits?, mode: PromptTurnMode
    ) throws -> JSONDictionary {
        var arguments: JSONDictionary = [
            "sessionId": .string(sessionId), "text": .string(""), "content": .array(content), "wait": .bool(wait),
            "permissionMode": .string(permissionMode), "nonInteractivePermissions": .string(nonInteractivePermissions),
            "streamWire": .bool(mode.streamWire), "terminalOutputCeiling": .integer(terminalOutputCeiling)
        ]
        if let permissionPolicy {
            arguments["permissionPolicy"] = try MCPClientArgumentEncoder.encode(permissionPolicy)
        }
        if let model { arguments["model"] = .string(model) }
        if let sessionOptions { arguments["sessionOptions"] = try MCPClientArgumentEncoder.encode(sessionOptions) }
        if let limits { arguments["limits"] = try MCPClientArgumentEncoder.encode(limits) }
        if mode.direct { arguments["direct"] = .bool(true) }
        if let fs = mode.fs { arguments["fs"] = .bool(fs) }
        if let authPolicy = mode.authPolicy { arguments["authPolicy"] = .string(authPolicy) }
        if let turnToken = mode.turnToken { arguments["turnToken"] = .string(turnToken) }
        if let configCwd = mode.configCwd { arguments["configCwd"] = .string(configCwd) }
        return arguments
    }
}
