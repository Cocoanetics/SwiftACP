import Foundation
import JSONFoundation

/// How far an agent's `fs/*` requests may reach on disk.
public enum FileSystemAccessScope: Sendable, Hashable {
    /// Confine every path to the session's own working directory — the `cwd` sent on
    /// `session/new`, `session/load` or `session/resume`. The default: an agent asking
    /// the client to touch a file outside the workspace is refused.
    ///
    /// Containment is decided on the *resolved* path, so a symlinked working directory
    /// keeps working while a symlink pointing out of the workspace does not.
    case sessionRoot
    /// No confinement — the handler sees whatever path the agent sent. For an embedder
    /// that mediates filesystem access itself.
    case unrestricted
}

/// A `fs/*` request carrying the session it belongs to and the path it names.
protocol FileSystemPathRequest {
    var sessionId: SessionId { get }
    var path: String { get set }
}

extension ReadTextFileRequest: FileSystemPathRequest {}
extension WriteTextFileRequest: FileSystemPathRequest {}

/// Confines the paths an agent sends to `fs/read_text_file` and `fs/write_text_file`,
/// porting acpx's fs-safe roots (0.16.0, 0.18.0). The client — not the agent — decides
/// what is reachable, and an agent that names a path outside the workspace is refused
/// rather than served.
enum FileSystemContainment {
    enum Access { case read, write }

    /// ACP's resource-not-found code, so an agent can tell a new file from a failed read.
    static let resourceNotFoundCode = -32002

    /// The resolved path to hand the handler, or the JSON-RPC error to answer with.
    ///
    /// A read must name an existing regular file; a write need not exist yet, so its
    /// deepest existing ancestor is resolved and the missing components re-appended —
    /// where the file *would* land still has to be inside the root.
    static func resolve(path: String, under root: String, for access: Access) throws -> String {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
        let requested =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: rootURL)
        let resolved = resolvingExistingPrefix(of: requested)

        guard isWithin(root: rootURL.path, resolved.path) else {
            throw JSONRPCError.invalidParams(
                "Path is outside the session's working directory: \(path)")
        }
        if access == .read {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            else {
                throw JSONRPCError.serverError(
                    code: resourceNotFoundCode, message: "Resource not found: \(path)",
                    data: .string(URL(fileURLWithPath: resolved.path).absoluteString))
            }
            // A socket, fifo or device is not something to hand an agent as text.
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw JSONRPCError.invalidParams("Not a regular file: \(path)")
            }
        }
        return resolved.path
    }

    /// Resolve symlinks across the part of the path that exists, then re-append what
    /// does not. Resolving only the existing prefix is what keeps a lexical `..` from
    /// naming an unrelated target: the prefix is a real directory before the remainder
    /// is standardized onto it.
    private static func resolvingExistingPrefix(of url: URL) -> URL {
        let fileManager = FileManager.default
        var current = url.standardizedFileURL
        if fileManager.fileExists(atPath: current.path) {
            return current.resolvingSymlinksInPath()
        }
        var missing: [String] = []
        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return url.standardizedFileURL }
            missing.insert(current.lastPathComponent, at: 0)
            current = parent
        }
        var resolved = current.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    /// Path containment by components, not by string prefix: `/work/bin` is inside
    /// `/work`, `/workspace` is not.
    private static func isWithin(root: String, _ path: String) -> Bool {
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
