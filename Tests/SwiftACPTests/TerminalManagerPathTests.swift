#if os(macOS) || os(Linux)
@testable import SwiftACP
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How a terminal's command is found on `PATH` (#82): as libuv's spawn finds it, and
/// failing in Node's words.
extension TerminalManagerTests {
    /// A relative `PATH` entry names a directory under the command's own directory,
    /// even when that directory is itself relative, as Node's spawn finds it.
    @Test func aRelativePathEntryIsFoundFromTheCommandsDirectory() async throws {
        let root = try workspace()
        try FileManager.default.createDirectory(atPath: root + "/sub/bin", withIntermediateDirectories: true)
        // A link to `pwd` rather than a script written here: a command another test
        // starts meanwhile can hold a file being written open for an instant, and
        // running it then is `ETXTBSY`.
        try FileManager.default.createSymbolicLink(atPath: root + "/sub/bin/tool", withDestinationPath: "/bin/pwd")
        // `sub`, as seen from this process's own directory: a relative `cwd` is resolved
        // from there, as in Node. (Changing this process's directory would race the
        // tests running beside this one.)
        let relativeSub = Self.relativePath(from: FileManager.default.currentDirectoryPath, to: root + "/sub")
        let process = try ChildProcess.spawn(
            command: "tool", arguments: [], cwd: relativeSub, environment: ["PATH": "bin"])
        let output = TerminalOutput(limit: 4096)
        let text: String = await withCheckedContinuation { continuation in
            process.start(onOutput: { output.append($0) }, onExit: { _ in
                continuation.resume(returning: output.read().text)
            })
        }
        process.stopReading()
        #expect(text == "\(root)/sub\n")
    }

    /// libuv's `PATH` search, after musl's `execvp`, in Node's words: a match that
    /// cannot run is `EACCES`, and the search goes on past it; an entry that is a file
    /// is `ENOTDIR` and a symlink loop `ELOOP`, which `spawn` throws naming no command.
    /// Only a command not found at all goes to the shell. acpx 0.19.1 answered each
    /// the same.
    @Test func thePathIsSearchedAsLibuvSearchesIt() async throws {
        let root = try workspace()
        let files = FileManager.default
        try files.createDirectory(atPath: root + "/dir/tool", withIntermediateDirectories: true)
        try files.createDirectory(atPath: root + "/dir/my tool", withIntermediateDirectories: true)
        try files.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: root + "/bin/tool", withDestinationPath: "/bin/echo")
        try files.createDirectory(atPath: root + "/loop", withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: root + "/loop/tool", withDestinationPath: root + "/loop/tool")
        try "x".write(toFile: root + "/file", atomically: true, encoding: .utf8)
        let manager = TerminalManager(cwd: root)
        func failure(_ command: String, path: String) async -> String? {
            do {
                _ = try await run(manager, command, env: [EnvVariable(name: "PATH", value: path)])
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(await failure("tool", path: "\(root)/dir") == "spawn tool EACCES")
        #expect(await failure("tool", path: "\(root)/dir:\(root)/file") == "spawn tool EACCES")
        #expect(await failure("tool", path: "\(root)/file") == "spawn ENOTDIR")
        #expect(await failure("tool", path: "\(root)/file:\(root)/nope") == "spawn tool ENOENT")
        #expect(await failure("tool", path: "\(root)/loop:\(root)/bin") == "spawn ELOOP")
        #expect(await failure("my tool", path: "\(root)/dir") == "spawn my tool EACCES")
        #expect(await failure(String(repeating: "x", count: 256), path: "\(root)/bin") == "spawn ENAMETOOLONG")
        let path = [EnvVariable(name: "PATH", value: "\(root)/dir:\(root)/bin")]
        let found = try await run(manager, "tool", ["found"], env: path)
        #expect(found.output.output == "found\n")
    }

    /// `to` relative to `from`; both absolute and physical.
    static func relativePath(from: String, to: String) -> String {
        let physical = realpath(from, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let fromParts = (physical ?? from).split(separator: "/")
        let toParts = to.split(separator: "/")
        var common = 0
        while common < min(fromParts.count, toParts.count), fromParts[common] == toParts[common] { common += 1 }
        let up = Array(repeating: "..", count: fromParts.count - common)
        return (up + toParts[common...].map(String.init)).joined(separator: "/")
    }
}
#endif
