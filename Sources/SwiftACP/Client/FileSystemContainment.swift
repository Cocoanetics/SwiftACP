import Foundation
import JSONFoundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How far an agent's `fs/*` requests may reach on disk.
public enum FileSystemAccessScope: Sendable, Hashable {
    /// Confine every path to the session's own working directory — the `cwd` sent on
    /// `session/new`, `session/load` or `session/resume`. The default: an agent asking
    /// the client to touch a file outside the workspace is refused.
    ///
    /// Containment is checked twice, as acpx does: lexically on the path the agent
    /// sent, then on the real path, so a symlink pointing out of the workspace is
    /// refused while one staying inside keeps working.
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
/// porting acpx's `FileSystemHandlers` and the fs-safe root it delegates to (0.16.0,
/// 0.18.0). The client — not the agent — decides what is reachable.
///
/// Two stages, in acpx's order:
///
/// 1. ``lexicallyContained(_:under:)`` — `resolvePathWithinRoot`: the path must be
///    absolute and, once `.`/`..` are collapsed, inside the session's working
///    directory. Nothing on disk is consulted.
/// 2. ``resolveWithinRealRoot(_:under:)`` — fs-safe's `follow-within-root`: symlinks
///    are followed, and one that leaves the real workspace is refused.
///
/// A write asks for permission *between* the two, so a path that is plainly outside
/// the workspace is refused without asking anyone, while one that merely looks
/// suspicious on disk is still offered to the user first — which is also what acpx
/// does.
///
/// Every refusal is thrown the way acpx's handlers throw it; see ``refused(_:)``.
enum FileSystemContainment {
    enum Access { case read, write }

    /// ACP's resource-not-found code, so an agent can tell a new file from a failed read.
    static let resourceNotFoundCode = -32002

    // MARK: - Refusals, in acpx's words

    static let mustBeAbsolute = "Path must be absolute: "
    static let outsideCwdSubtree = "Path is outside allowed cwd subtree: "
    static let outsideWorkspaceRoot = "file is outside workspace root"
    static let notAFile = "not a file"
    static let notARegularFileUnderRoot = "path is not a regular file under root"
    static let aliasEscapeBlocked = "path alias escape blocked"

    /// A refusal as the agent receives it. acpx throws a plain `Error`, and the ACP SDK
    /// answers any such throw from a request handler with `-32603 "Internal error"`,
    /// carrying the message in `data.details` — not in `message`, and not as
    /// `-32602`. Agents see exactly this shape from acpx.
    static func refused(_ details: String) -> JSONRPCError {
        JSONRPCError(
            code: -32603, message: "Internal error", data: .object(["details": .string(details)]))
    }

    /// acpx's `RequestError.resourceNotFound(pathToFileURL(path).href)`: the URI is in
    /// both the message and `data.uri`, and is built from the path the agent asked for
    /// (normalized, not symlink-resolved), so it names what the agent named.
    static func resourceNotFound(_ path: String) -> JSONRPCError {
        let uri = URL(fileURLWithPath: path).absoluteString
        return JSONRPCError(
            code: resourceNotFoundCode, message: "Resource not found: \(uri)",
            data: .object(["uri": .string(uri)]))
    }

    // MARK: - Stage 1: lexical

    /// acpx's `resolvePathWithinRoot`. Returns the path collapsed of `.`/`..` — the
    /// form acpx reports in its refusal and builds a not-found URI from.
    ///
    /// Deliberately lexical: the session root is the working directory as the client
    /// sent it, and neither side is symlink-resolved, so an agent that answers with the
    /// real path of a symlinked working directory is refused just as it is upstream.
    static func lexicallyContained(_ path: String, under root: String) throws -> String {
        // `isAbsolutePath` rather than a leading "/" so a Windows drive path is not
        // mistaken for a relative one.
        guard (path as NSString).isAbsolutePath else {
            throw refused(mustBeAbsolute + path)
        }
        let normalized = lexicallyNormalized(path)
        guard isWithin(root: lexicallyNormalized(root), normalized) else {
            throw refused(outsideCwdSubtree + normalized)
        }
        return normalized
    }

    /// Node's `path.resolve` on an absolute path: collapse empty and `.` components and
    /// fold `..` into its parent, without touching the disk. Foundation's
    /// `standardizingPath` is not a substitute — it strips `/private` from
    /// `/private/tmp` and resolves `..` through real symlinks "where possible".
    static func lexicallyNormalized(_ path: String) -> String {
        #if os(Windows)
            return URL(fileURLWithPath: path).standardizedFileURL.path
        #else
            var components: [Substring] = []
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                switch component {
                case ".": continue
                case "..": if !components.isEmpty { components.removeLast() }
                default: components.append(component)
                }
            }
            return "/" + components.joined(separator: "/")
        #endif
    }

    // MARK: - Stage 2: on disk

    /// fs-safe's `follow-within-root`: follow symlinks across the part of the path that
    /// exists, and refuse the path if that lands outside the real workspace. Returns the
    /// resolved path the handler opens.
    ///
    /// Whether the object exists, is a regular file, or is hard-linked elsewhere is left
    /// to ``LocalFileSystem`` on the open descriptor — a path checked here and opened
    /// later can be swapped in between.
    ///
    /// A write need not exist yet, so its deepest existing ancestor is resolved and the
    /// missing components re-appended: where the file *would* land still has to be
    /// inside the root.
    static func resolveWithinRealRoot(_ path: String, under root: String) throws -> String {
        let realRoot = physicallyResolved(root)
        let resolved = physicallyResolved(path)
        guard isWithin(root: realRoot, resolved) else {
            throw refused(outsideWorkspaceRoot)
        }
        return resolved
    }

    /// Resolve the path the way the kernel will: symlinks followed and `..` applied to
    /// what they *point at*, not folded into the text first. acpx 0.18.0 changed to
    /// exactly this ("preserve symlink and parent-directory traversal … instead of
    /// accessing an unrelated lexical target"): with `link -> /elsewhere`,
    /// `link/../file` is `/file`, not the sibling `file` a lexical fold would name.
    ///
    /// The deepest prefix that exists is handed to `realpath(3)` untouched; the
    /// missing remainder cannot contain a symlink yet, so it is appended and only then
    /// folded.
    static func physicallyResolved(_ path: String) -> String {
        #if os(Windows)
            return resolvingExistingPrefix(of: URL(fileURLWithPath: path)).path
        #else
            var existing = path
            var missing: [String] = []
            while true {
                if let real = realpath(existing, nil) {
                    defer { free(real) }
                    let base = String(cString: real)
                    let joined = ([base] + missing).joined(separator: "/")
                    return missing.isEmpty ? base : lexicallyNormalized(joined)
                }
                let parent = (existing as NSString).deletingLastPathComponent
                guard parent != existing, !parent.isEmpty else { return lexicallyNormalized(path) }
                missing.insert((existing as NSString).lastPathComponent, at: 0)
                existing = parent
            }
        #endif
    }

    #if os(Windows)
    /// Windows has no `realpath`: resolve symlinks across the part of the path that
    /// exists, then re-append what does not.
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
    #endif

    /// Containment by path components, not by string prefix — `/work/bin` is inside
    /// `/work` while `/workspace` is not, and the root itself counts as inside, as in
    /// fs-safe's `isPathInside`.
    ///
    /// Both sides arrive already normalized (lexically for stage 1, by `realpath` for
    /// stage 2), so the split is purely textual. `URL.standardizedFileURL` must not be
    /// used here: on Darwin it drops `/private` from `/private/tmp/…` only when the
    /// shortened path exists — so an existing root and a not-yet-existing file beneath
    /// it came out with different prefixes, and every new file looked outside the root.
    private static func isWithin(root: String, _ target: String) -> Bool {
        let rootComponents = components(of: root)
        let targetComponents = components(of: target)
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func components(of path: String) -> [String] {
        #if os(Windows)
            // Windows paths need Foundation's separator and drive handling, and compare
            // case-insensitively — fs-safe lowercases a drive path before comparing
            // (`resolveWindowsPathForComparison`). Like fs-safe, 8.3 short names are not
            // expanded: `RUNNER~1` and `runneradmin` are different text.
            return URL(fileURLWithPath: path).standardizedFileURL.pathComponents.map { $0.lowercased() }
        #else
            return path.split(separator: "/").map(String.init)
        #endif
    }
}
