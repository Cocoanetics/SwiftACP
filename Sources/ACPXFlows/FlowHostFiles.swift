import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The host's scripts on disk, where Node can load them: in a directory of this user's
/// caches named for what they hold, so a CLI of another version never uses this one's.
/// Node runs whatever is there, so nothing is taken on trust: the directory must be this
/// user's and writable by no one else, and each script a file of this user's holding
/// exactly what this CLI embeds — or it is written again. (A shared temporary directory
/// would let another user leave scripts there first.)
enum FlowHostFiles {
    struct Installed {
        let host: String
        let runtime: String
        let sucrase: String
    }

    /// A cache directory that is not this user's, or not a directory.
    struct UnsafeDirectory: Error, LocalizedError {
        let path: String
        var errorDescription: String? {
            "The flow host's cache is not safe to use (not a directory of this user's): \(path)"
        }
    }

    static func install(root: URL = cacheRoot()) throws -> Installed {
        let scripts = [
            ("flow-runtime.mjs", FlowHostScripts.runtime), ("flow-sucrase.mjs", FlowHostScripts.sucrase),
            ("flow-host.mjs", FlowHostScripts.host)
        ]
        let contents = scripts.map(\.1).joined(separator: "\u{0}")
        let directory = root
            .appendingPathComponent("acpx-flow-host-\(FlowRuntimeSupport.shortHash(contents))", isDirectory: true)
        try makePrivateDirectory(root)
        try makePrivateDirectory(directory)
        for (name, text) in scripts {
            let file = directory.appendingPathComponent(name)
            let data = Data(text.utf8)
            guard !holds(file, data) else { continue }
            // Owner-only whatever the umask, written whole under a temporary name, then
            // moved into place: another acpx starting a flow at the same time finds the old
            // file or the new, never half.
            try FlowRunStore.writePrivateFile(data, to: file)
        }
        return Installed(
            host: directory.appendingPathComponent("flow-host.mjs").path,
            runtime: directory.appendingPathComponent("flow-runtime.mjs").path,
            sucrase: directory.appendingPathComponent("flow-sucrase.mjs").path)
    }

    /// `~/Library/Caches/SwiftACP`: this user's own.
    static func cacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("SwiftACP", isDirectory: true)
    }

    /// `directory`, made owner-only if missing; one that is there must be a directory of
    /// this user's — not a link to one — and loses any write access others have to it.
    static func makePrivateDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw UnsafeDirectory(path: directory.path)
        }
        if info.st_mode & 0o022 != 0, chmod(directory.path, info.st_mode & 0o7777 & ~0o022) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
    }

    /// Whether `file` is a file of this user's — not a link — holding exactly `data`.
    static func holds(_ file: URL, _ data: Data) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0, info.st_size == off_t(data.count)
        else { return false }
        return FileManager.default.contents(atPath: file.path) == data
    }
}
