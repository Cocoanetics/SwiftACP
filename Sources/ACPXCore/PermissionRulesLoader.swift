import Foundation
import SwiftACP

/// acpx's `loadPermissionPolicySpec` and `parsePermissionPolicy`: the permission policy
/// `--permission-policy` (or `--policy`) gives — inline JSON when it starts with `{`,
/// else a file, relative to the working directory — read with acpx's error messages.
public enum PermissionRulesLoader {
    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The policy `spec` names, or `nil` for none.
    public static func load(_ spec: String?, cwd: String) throws -> PermissionRules? {
        let trimmed = spec?.javaScriptTrimmed ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") {
            return try parse(try json(trimmed), source: "--permission-policy")
        }
        let path = URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
            .standardizedFileURL.path
        return try parse(try json(try read(path)), source: path)
    }

    private static func json(_ text: String) throws -> WireJSON {
        do {
            return try WireJSON.parse(text)
        } catch let error as WireJSON.SyntaxError {
            throw Invalid(message: error.message)
        }
    }

    /// Node's `fs.readFile`, as far as its failures read.
    private static func read(_ path: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw Invalid(message: "ENOENT: no such file or directory, open '\(path)'")
        }
        if isDirectory.boolValue { throw Invalid(message: "EISDIR: illegal operation on a directory, read") }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Invalid(message: "EACCES: permission denied, open '\(path)'")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `parsePermissionPolicy`.
    static func parse(_ value: WireJSON, source: String) throws -> PermissionRules {
        guard case .object = value else {
            throw Invalid(message: "\(source): permission policy must be a JSON object")
        }
        func rules(_ key: String) throws -> [String]? {
            guard let list = value[key], list != .null else { return nil }
            guard case .array(let entries) = list else {
                throw Invalid(message: "\(source): permission policy \(key) must be an array of strings")
            }
            return try entries.map { entry in
                guard let text = entry.stringValue, !text.javaScriptTrimmed.isEmpty else {
                    let problem = "must contain only non-empty strings"
                    throw Invalid(message: "\(source): permission policy \(key) \(problem)")
                }
                return text.javaScriptTrimmed
            }
        }
        var policy = PermissionRules(
            autoApprove: try rules("autoApprove"), autoDeny: try rules("autoDeny"), escalate: try rules("escalate"))
        if let action = value["defaultAction"], action != .null {
            guard let parsed = action.stringValue.flatMap(PermissionRules.Action.init(rawValue:)) else {
                let problem = "must be one of approve, deny, escalate"
                throw Invalid(message: "\(source): permission policy defaultAction \(problem)")
            }
            policy.defaultAction = parsed
        }
        return policy
    }
}
