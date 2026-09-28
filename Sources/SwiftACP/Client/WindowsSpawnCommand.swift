import Foundation

/// How acpx starts a command on Windows (`buildAgentSpawnCommand`, `src/spawn-command-options.ts`,
/// 0.19.3), for a launch probe (#265). A `.cmd` or `.bat`, such as the shim npm installs for
/// `gemini`, runs through `cmd.exe` on a command line escaped for it and passed as it is. Anything
/// else is started directly. It looks only at the file system it is given, so it is checked on
/// every platform (`acpx-windows-spawn.json`).
struct WindowsSpawnCommand: Equatable {
    var command: String
    var arguments: [String]
    /// Node's `windowsVerbatimArguments`: the command line is the arguments as they are, unquoted.
    var verbatimArguments = false

    /// What the resolution may ask of the disk.
    struct FileSystem: Sendable {
        /// Node's `fs.existsSync`: a file or a directory is there.
        var exists: @Sendable (String) -> Bool
        /// What libuv's `search_path` looks for: a file, not a directory.
        var isFile: @Sendable (String) -> Bool

        /// This machine's.
        static let local = FileSystem(
            exists: { FileManager.default.fileExists(atPath: $0) },
            isFile: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            })
    }
}

extension WindowsSpawnCommand {
    /// acpx's `buildAgentSpawnCommand` on `win32`, in the agent's environment and directory.
    init(
        command: String, arguments: [String], environment: [String: String], cwd: String?, fileSystem: FileSystem
    ) {
        let resolved = Self.resolve(command, environment: environment, cwd: cwd, fileSystem: fileSystem)
        let extensionName = WindowsPath.extname(resolved ?? command).lowercased()
        guard extensionName == ".cmd" || extensionName == ".bat" else {
            self.init(command: command, arguments: arguments)
            return
        }
        // A missing script is run all the same: cmd.exe then says so on stderr.
        let script = WindowsPath.normalize(resolved ?? command)
        let doubleEscape = Self.isNodeModulesShim(script)
        let escaped = arguments.map { Self.escapeArgument($0, doubleEscape: doubleEscape) }
        let shellCommand = ([Self.escapeCommand(script)] + escaped).joined(separator: " ")
        self.init(
            command: Self.value(of: "COMSPEC", in: environment) ?? "cmd.exe",
            arguments: ["/d", "/s", "/c", "\"\(shellCommand)\""], verbatimArguments: true)
    }

    // MARK: - Resolution

    /// acpx's `resolveWindowsCommand`: the file `command` names, with each of `PATHEXT`'s
    /// extensions if it has none. With a directory, it is taken from `cwd`; otherwise it is looked
    /// for in each of `PATH`'s directories in turn.
    static func resolve(
        _ command: String, environment: [String: String], cwd: String?, fileSystem: FileSystem
    ) -> String? {
        let candidates = candidates(for: command, environment: environment)
        if hasDirectory(command) {
            return candidates.lazy.map { fromWorkingDirectory($0, cwd) }.first(where: fileSystem.exists)
        }
        guard let path = value(of: "PATH", in: environment), !path.isEmpty else { return nil }
        for directory in split(path, at: ";") {
            let directory = TerminalOutputLimit.javaScriptTrimmed(directory)
            guard !directory.isEmpty else { continue }
            let found = candidates.lazy
                .map { fromWorkingDirectory(WindowsPath.join(directory, $0), cwd) }
                .first(where: fileSystem.exists)
            if let found { return found }
        }
        return nil
    }

    /// acpx's `resolveInstalledExecutable` on `win32`: the file `command` resolves to, found as
    /// ``resolve(_:environment:cwd:fileSystem:)`` finds it with no directory for a relative path,
    /// then made absolute against `processDirectory` (Node's `process.cwd()`). A directory is none.
    static func installedExecutable(
        _ command: String, environment: [String: String], fileSystem: FileSystem, processDirectory: String
    ) -> String? {
        guard let resolved = resolve(command, environment: environment, cwd: nil, fileSystem: fileSystem),
              fileSystem.isFile(resolved)
        else { return nil }
        return WindowsPath.resolve([resolved], processDirectory: processDirectory)
    }

    /// acpx's `commandCandidates`: `command` as it is if it has an extension, else with each of
    /// `PATHEXT`'s.
    private static func candidates(for command: String, environment: [String: String]) -> [String] {
        guard WindowsPath.extname(command).isEmpty else { return [command] }
        return split(value(of: "PATHEXT", in: environment) ?? ".COM;.EXE;.BAT;.CMD", at: ";")
            .map { TerminalOutputLimit.javaScriptTrimmed($0).lowercased() }
            .filter { !$0.isEmpty }
            .map { command + $0 }
    }

    /// acpx's `commandHasPath`.
    private static func hasDirectory(_ command: String) -> Bool {
        command.utf16.contains { $0 == 0x2F || $0 == 0x5C } || WindowsPath.isAbsolute(command)
    }

    /// acpx's `fromWorkingDirectory`.
    private static func fromWorkingDirectory(_ path: String, _ cwd: String?) -> String {
        guard let cwd, !WindowsPath.isAbsolute(path) else { return path }
        return WindowsPath.resolve([cwd, path])
    }

    /// acpx's `readWindowsEnvValue`: the variable named `key` in any case. Of two spellings, the
    /// first in code-unit order, the one Node keeps when it starts a child.
    static func value(of key: String, in environment: [String: String]) -> String? {
        environment.keys
            .filter { $0.uppercased() == key }
            .min { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            .flatMap { environment[$0] }
    }

    /// JavaScript's `split`, on one character.
    private static func split(_ text: String, at separator: Unicode.Scalar) -> [String] {
        text.unicodeScalars.split(separator: separator, omittingEmptySubsequences: false).map { String($0) }
    }

    // MARK: - cmd.exe

    /// `CMD_META_CHAR_RE`: what cmd.exe reads specially, each escaped with a caret.
    private static let metaCharacters: Set<Unicode.Scalar> = [
        "(", ")", "]", "[", "%", "!", "^", "\"", "`", "<", ">", "&", "|", ";", ",", " ", "*", "?"
    ]

    private static func escapeMeta(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if metaCharacters.contains(scalar) { escaped.append("^") }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    /// acpx's `escapeCmdCommand`.
    static func escapeCommand(_ command: String) -> String {
        escapeMeta(command)
    }

    /// acpx's `escapeCmdArgument`, cross-spawn's: the backslash before a quote and the one at the
    /// end doubled, quotes escaped, the whole quoted, and each metacharacter escaped — twice for
    /// a `node_modules\.bin` shim, which cmd.exe reads a second time. As acpx's lookahead matches,
    /// only the last backslash of a run is doubled, where the rule it follows doubles them all
    /// (openclaw/acpx#830).
    static func escapeArgument(_ argument: String, doubleEscape: Bool) -> String {
        let scalars = Array(argument.unicodeScalars)
        var doubled = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\", index + 1 < scalars.count, scalars[index + 1] == "\"" {
                doubled.append(contentsOf: #"\\\""#.unicodeScalars)
                index += 2
            } else {
                if scalars[index] == "\"" { doubled.append("\\") }
                doubled.append(scalars[index])
                index += 1
            }
        }
        if doubled.last == "\\" { doubled.append("\\") }
        let escaped = escapeMeta("\"" + String(doubled) + "\"")
        return doubleEscape ? escapeMeta(escaped) : escaped
    }

    /// `CMD_SHIM_RE`, `/node_modules[\\/].bin[\\/][^\\/]+\.cmd$/iu`: a `.cmd` right in a
    /// `node_modules` `bin` directory. The regex's `.` before `bin` is any character but a line's
    /// end, and its case folding matches `ſ` to `s`.
    static func isNodeModulesShim(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        guard let lastSeparator = scalars.lastIndex(where: { $0 == "\\" || $0 == "/" }),
              scalars.count - lastSeparator - 1 > 4, matches(scalars.suffix(4), ".cmd")
        else { return false }
        let start = lastSeparator - 17
        guard start >= 0 else { return false }
        let lineEnds: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}"]
        return matches(scalars[start..<(start + 12)], "node_modules")
            && (scalars[start + 12] == "\\" || scalars[start + 12] == "/")
            && !lineEnds.contains(scalars[start + 13])
            && matches(scalars[(start + 14)..<(start + 17)], "bin")
    }

    /// Whether `scalars` spell `lowercase` in any case, as a `/iu` regex compares them: ASCII
    /// letters in either case, and the two others whose simple case folding is ASCII.
    private static func matches(_ scalars: some Collection<Unicode.Scalar>, _ lowercase: String) -> Bool {
        func folded(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            switch scalar.value {
            case 0x41...0x5A: return Unicode.Scalar(scalar.value + 0x20) ?? scalar
            case 0x17F: return "s"
            case 0x212A: return "k"
            default: return scalar
            }
        }
        return scalars.count == lowercase.unicodeScalars.count
            && zip(scalars, lowercase.unicodeScalars).allSatisfy { folded($0) == $1 }
    }
}
