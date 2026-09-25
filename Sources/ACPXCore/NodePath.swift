import Foundation

/// Node's POSIX `path` functions and file error messages, where acpx's output carries
/// what they give.
public enum NodePath {
    /// `path.resolve(path)`: absolute against this process's directory, and normalized.
    public static func resolve(_ path: String) -> String {
        ACPXPaths.resolve(path, base: FileManager.default.currentDirectoryPath)
    }

    /// `path.join(base, path)` for an absolute `base`: the two joined and normalized, a
    /// trailing `/` kept.
    static func join(_ base: String, _ path: String) -> String {
        let joined = [base, path].filter { !$0.isEmpty }.joined(separator: "/")
        let normalized = resolve(joined)
        return joined.hasSuffix("/") && normalized != "/" ? normalized + "/" : normalized
    }

    /// `path.relative(from, to)`: the way from one to the other, `""` when they are one.
    static func relative(from: String, to: String) -> String {
        let (start, end) = (resolve(from).split(separator: "/"), resolve(to).split(separator: "/"))
        var common = 0
        while common < min(start.count, end.count), start[common] == end[common] { common += 1 }
        let parts = Array(repeating: Substring(".."), count: start.count - common) + end[common...]
        return parts.joined(separator: "/")
    }

    /// `path.dirname(path)`: all of it but its last part — `.` when it has only one.
    static func dirname(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        if slash == trimmed.startIndex { return "/" }
        var parent = trimmed[..<slash]
        while parent.count > 1, parent.hasSuffix("/") { parent = parent.dropLast() }
        return String(parent)
    }

    /// `path.basename(path)`: its last part.
    static func basename(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed.split(separator: "/").last ?? "")
    }

    /// Node's message for a failed `syscall` on `path`, as libuv names the error:
    /// `ENOENT: no such file or directory, open '<path>'`.
    static func errorMessage(_ code: Int32, syscall: String, path: String? = nil) -> String {
        let (name, text) = libuvErrors[code] ?? ("E\(code)", String(cString: strerror(code)).lowercased())
        return "\(name): \(text), \(syscall)" + (path.map { " '\($0)'" } ?? "")
    }

    private static let libuvErrors: [Int32: (String, String)] = [
        ENOENT: ("ENOENT", "no such file or directory"), EACCES: ("EACCES", "permission denied"),
        EISDIR: ("EISDIR", "illegal operation on a directory"), ENOTDIR: ("ENOTDIR", "not a directory"),
        ELOOP: ("ELOOP", "too many symbolic links encountered"), EPERM: ("EPERM", "operation not permitted"),
        EEXIST: ("EEXIST", "file already exists"), ENAMETOOLONG: ("ENAMETOOLONG", "name too long"),
        EMFILE: ("EMFILE", "too many open files"), ENOSPC: ("ENOSPC", "no space left on device"),
        EROFS: ("EROFS", "read-only file system")
    ]
}
