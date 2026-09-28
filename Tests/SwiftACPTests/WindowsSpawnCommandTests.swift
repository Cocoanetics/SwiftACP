@testable import SwiftACP
import Foundation
import Testing

/// How a launch probe starts its command on Windows (#265), checked on every platform. acpx's side
/// is checked against acpx's own code (`acpx-windows-spawn.json`, made by
/// `scripts/windows-spawn-vectors`): 0.19.3's `buildAgentSpawnCommand` and
/// `resolveWindowsCommand`, run with Node's `path.win32` and a Windows file system of each case's
/// files, and `path.win32` itself. libuv's side, what Node then starts, is checked against libuv's
/// own examples and rules.
@Suite(.timeLimit(.minutes(1)))
struct WindowsSpawnCommandTests {
    private struct Fixture: Decodable {
        let spawns: [Spawn]
        let installed: [Installed]
        let paths: Paths
    }

    private struct Installed: Decodable {
        let name: String
        let command: String
        let env: [String: String]
        let files: [String]
        let directories: [String]
        let processDirectory: String
        let expected: String?
    }

    private struct Spawn: Decodable {
        let name: String
        let command: String
        let args: [String]
        let env: [String: String]
        let cwd: String
        let files: [String]
        let resolved: String?
        let expected: Expected
    }

    private struct Expected: Decodable {
        let command: String
        let args: [String]
        let windowsVerbatimArguments: Bool?
    }

    private struct Paths: Decodable {
        let normalize: [PathCase<String>]
        let resolve: [ResolveCase]
        let join: [JoinCase]
        let isAbsolute: [PathCase<Bool>]
        let extname: [PathCase<String>]
    }

    private struct PathCase<Output: Decodable & Equatable>: Decodable {
        let input: String
        let output: Output
    }

    private struct ResolveCase: Decodable {
        let cwd: String
        let input: String
        let output: String
    }

    private struct JoinCase: Decodable {
        let input: [String]
        let output: String
    }

    private static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/acpx-windows-spawn.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// A Windows file system holding `files` and `directories`, as the fixture's fake one holds them:
    /// names compared in any case, either slash, `.` and `..` read as Win32 reads them, and a
    /// relative path taken from `processDirectory`.
    private static func fileSystem(
        _ files: [String], directories: [String] = [], processDirectory: String = #"C:\work"#
    ) -> WindowsSpawnCommand.FileSystem {
        let canonical: @Sendable (String) -> String = {
            WindowsPath.resolve([$0], processDirectory: processDirectory).lowercased()
        }
        let fileSet = Set(files.map(canonical))
        let directorySet = Set(directories.map(canonical))
        return WindowsSpawnCommand.FileSystem(
            exists: { fileSet.contains(canonical($0)) || directorySet.contains(canonical($0)) },
            isFile: { fileSet.contains(canonical($0)) })
    }

    /// Each case's command, started as acpx starts it: an npm `.cmd` shim through `cmd.exe`,
    /// escaped for it, and anything else as it is.
    @Test func eachCommandStartsAsAcpxStartsIt() throws {
        for spawn in try Self.fixture().spawns {
            let files = Self.fileSystem(spawn.files)
            let started = WindowsSpawnCommand(
                command: spawn.command, arguments: spawn.args, environment: spawn.env, cwd: spawn.cwd,
                fileSystem: files)
            let expected = WindowsSpawnCommand(
                command: spawn.expected.command, arguments: spawn.expected.args,
                verbatimArguments: spawn.expected.windowsVerbatimArguments ?? false)
            #expect(started == expected, "\(spawn.name)")
            let resolved = WindowsSpawnCommand.resolve(
                spawn.command, environment: spawn.env, cwd: spawn.cwd, fileSystem: files)
            #expect(resolved == spawn.resolved, "\(spawn.name)")
        }
    }

    /// An installed command, found as acpx's `resolveInstalledExecutable` finds it on Windows, which
    /// `AgentRegistry.which` is there.
    @Test func installedCommandsAreFoundAsAcpxFindsThem() throws {
        for install in try Self.fixture().installed {
            let files = Self.fileSystem(
                install.files, directories: install.directories, processDirectory: install.processDirectory)
            let found = WindowsSpawnCommand.installedExecutable(
                install.command, environment: install.env, fileSystem: files,
                processDirectory: install.processDirectory)
            #expect(found == install.expected, "\(install.name)")
        }
    }

    /// Node's `path.win32`, which acpx resolves with.
    @Test func pathsAreReadAsNodesWin32Reads() throws {
        let paths = try Self.fixture().paths
        for path in paths.normalize {
            #expect(WindowsPath.normalize(path.input) == path.output, "normalize(\(path.input))")
        }
        for path in paths.resolve {
            #expect(WindowsPath.resolve([path.cwd, path.input]) == path.output, "resolve(\(path.cwd), \(path.input))")
        }
        for path in paths.join {
            #expect(WindowsPath.join(path.input[0], path.input[1]) == path.output, "join(\(path.input))")
        }
        for path in paths.isAbsolute {
            #expect(WindowsPath.isAbsolute(path.input) == path.output, "isAbsolute(\(path.input))")
        }
        for path in paths.extname {
            #expect(WindowsPath.extname(path.input) == path.output, "extname(\(path.input))")
        }
    }

    /// libuv's own examples for `quote_cmd_arg`, and what it leaves alone: no space, tab or quote,
    /// though a newline.
    @Test func argumentsAreQuotedAsLibuvQuotesThem() {
        let cases: [(argument: String, quoted: String)] = [
            (#"hello"world"#, #""hello\"world""#),
            (#"hello""world"#, #""hello\"\"world""#),
            (#"hello\world"#, #"hello\world"#),
            (#"hello\\world"#, #"hello\\world"#),
            (#"hello\"world"#, #""hello\\\"world""#),
            (#"hello\\"world"#, #""hello\\\\\"world""#),
            (#"hello world\"#, #""hello world\\""#),
            ("", #""""#),
            ("--version", "--version"),
            ("a b", #""a b""#),
            ("a\tb", "\"a\tb\""),
            ("new\nline", "new\nline")
        ]
        for (argument, quoted) in cases {
            #expect(LibuvSpawn.quoted(argument) == quoted, "\(argument)")
        }
    }

    /// The command line: the program's own name first, then its arguments, quoted, or as they are
    /// for a shim's `cmd.exe`.
    @Test func theCommandLineIsBuiltAsLibuvBuildsIt() {
        let shim = LibuvSpawn.commandLine(
            [#"C:\WINDOWS\system32\cmd.exe"#, "/d", "/s", "/c", #""C:\npm\gemini.cmd ^"--version^"""#], verbatim: true)
        #expect(shim == #"C:\WINDOWS\system32\cmd.exe /d /s /c "C:\npm\gemini.cmd ^"--version^"""#)
        let direct = LibuvSpawn.commandLine(["cmd", "/d", "/c", "echo hi", ""], verbatim: false)
        #expect(direct == #"cmd /d /c "echo hi" """#)
    }

    /// The program found as libuv's `search_path` finds it.
    @Test func theProgramIsFoundAsLibuvFindsIt() {
        let files = Self.fileSystem([
            #"C:\work\tool.exe"#, #"C:\bin\tool.com"#, #"C:\bin\tool.exe"#, #"C:\bin\gemini.cmd"#, #"C:\other\x.exe"#,
            #"D:\y.exe"#, #"C:\work\sub\z.exe"#, #"\\srv\share\u.exe"#, #"C:\semi;colon\s.exe"#
        ])
        func search(_ file: String, path: String = #"C:\bin;C:\other"#, currentDirectoryFirst: Bool = true) -> String? {
            LibuvSpawn.searchPath(
                file, cwd: #"C:\work"#, path: path, searchesCurrentDirectory: currentDirectoryFirst,
                isFile: files.isFile)
        }
        // The current directory first, unless Windows says not to; `.com` before `.exe`.
        #expect(search("tool") == #"C:\work\tool.exe"#)
        #expect(search("tool", currentDirectoryFirst: false) == #"C:\bin\tool.com"#)
        // Only `.com` and `.exe` are appended, never `PATHEXT`'s others; a name's own extension
        // is tried first.
        #expect(search("gemini") == nil)
        #expect(search("gemini.cmd") == #"C:\bin\gemini.cmd"#)
        #expect(search("x") == #"C:\other\x.exe"#)
        // A name with a directory is not looked for on `PATH`.
        #expect(search(#"sub\z"#) == #"C:\work\sub\z.exe"#)
        #expect(search(#"D:\y"#) == #"D:\y.exe"#)
        #expect(search("z", path: #"C:\bin"#, currentDirectoryFirst: false) == nil)
        // `PATH`'s directories: UNC, quoted around a `;`, empty, from a root, relative.
        #expect(search("u", path: #"\\srv\share"#) == #"\\srv\share\u.exe"#)
        #expect(search("s", path: #""C:\semi;colon";C:\bin"#) == #"C:\semi;colon\s.exe"#)
        #expect(search("x", path: #";;C:\other;"#) == #"C:\other\x.exe"#)
        #expect(search("x", path: #"\other"#) == #"C:\other\x.exe"#)
        #expect(search("z", path: "sub") == #"C:\work\sub\z.exe"#)
        #expect(search("z", path: "C:sub") == #"C:\work\sub\z.exe"#)
        #expect(search("z", path: "D:sub") == nil)
        #expect(search(".") == nil)
        #expect(search("") == nil)
    }

    /// The environment block: one spelling of each name, the first in code-unit order, as Node
    /// keeps it; sorted by name in any case, with what Windows needs taken from the parent when
    /// missing, as libuv builds it.
    @Test func theEnvironmentIsBuiltAsNodeAndLibuvBuildIt() {
        let block = LibuvSpawn.environmentBlock(
            ["b": "2", "A": "1", "PATH": #"C:\bin"#, "Path": #"C:\old"#, "temp": "mine"],
            parent: ["SystemRoot": #"C:\Windows"#, "TEMP": #"C:\Temp"#, "USERNAME": "me", "Other": "x"])
        let expected = "A=1\u{0}b=2\u{0}PATH=C:\\bin\u{0}SYSTEMROOT=C:\\Windows\u{0}temp=mine\u{0}USERNAME=me\u{0}\u{0}"
        #expect(block == Array(expected.utf16))
    }
}
