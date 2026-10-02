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
        /// Node's `fs.readFileSync(path, "utf8")`: a file's text, with what is not UTF-8 replaced;
        /// `nil` when it cannot be read.
        var read: @Sendable (String) -> String? = { _ in nil }

        /// This machine's.
        static let local = FileSystem(
            exists: { FileManager.default.fileExists(atPath: $0) },
            isFile: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            },
            read: { FileManager.default.contents(atPath: $0).map { String(decoding: $0, as: UTF8.self) } })
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

    /// acpx's `resolveClaudeCodeExecutable` on `win32`: the Claude Code program Claude's adapter is
    /// to run (`CLAUDE_CODE_EXECUTABLE`), unless the environment names one already.
    static func claudeCodeExecutable(
        environment: [String: String], cwd: String?, fileSystem: FileSystem, processDirectory: String
    ) -> String? {
        if let named = value(of: "CLAUDE_CODE_EXECUTABLE", in: environment), !named.isEmpty { return nil }
        return executablePath(
            "claude", environment: environment, cwd: cwd, fileSystem: fileSystem, processDirectory: processDirectory)
    }

    /// acpx's `resolveWindowsExecutablePath`: a native program for `command`, to start without a
    /// shell. An `.exe` is itself. A `.cmd`, `.bat` or `.ps1` shim gives the `.exe` beside it, or
    /// else the first `.exe` it names from its own directory. Anything else gives none.
    static func executablePath(
        _ command: String, environment: [String: String], cwd: String?, fileSystem: FileSystem,
        processDirectory: String
    ) -> String? {
        guard let resolved = resolve(command, environment: environment, cwd: cwd, fileSystem: fileSystem)
        else { return nil }
        let absolute = WindowsPath.resolve([resolved], processDirectory: processDirectory)
        let extensionName = WindowsPath.extname(absolute).lowercased()
        if extensionName == ".exe" { return absolute }
        guard [".cmd", ".bat", ".ps1"].contains(extensionName) else { return nil }
        let sibling = String(decoding: absolute.utf16.dropLast(extensionName.utf16.count), as: UTF16.self) + ".exe"
        if fileSystem.exists(sibling) { return sibling }
        return wrapperExecutable(absolute, fileSystem: fileSystem, processDirectory: processDirectory)
    }

    /// acpx's `resolveWindowsWrapperExecutable`: the first of the shim's quoted tokens that names,
    /// from `%dp0%` or `%~dp0`, an `.exe` that is there.
    private static func wrapperExecutable(
        _ wrapper: String, fileSystem: FileSystem, processDirectory: String
    ) -> String? {
        guard fileSystem.exists(wrapper), let text = fileSystem.read(wrapper) else { return nil }
        for token in quotedTokens(in: Array(text.utf16)) {
            guard let named = pathAfterScriptDirectory(in: token) else { continue }
            let candidate = WindowsPath.resolve(
                [WindowsPath.dirname(wrapper), named], processDirectory: processDirectory)
            if WindowsPath.extname(candidate).lowercased() == ".exe", fileSystem.exists(candidate) { return candidate }
        }
        return nil
    }

    /// `/"([^"\r\n]*)"/g`'s captures: what each pair of quotes within one line holds.
    private static func quotedTokens(in units: [UInt16]) -> [[UInt16]] {
        let quote: UInt16 = 0x22
        let lineEnds: Set<UInt16> = [0x0D, 0x0A]
        var tokens: [[UInt16]] = []
        var index = 0
        while index < units.count {
            guard units[index] == quote else {
                index += 1
                continue
            }
            let end = units[(index + 1)...].firstIndex { $0 == quote || lineEnds.contains($0) }
            if let end, units[end] == quote {
                tokens.append(Array(units[(index + 1)..<end]))
                index = end + 1
            } else {
                index += 1
            }
        }
        return tokens
    }

    /// acpx's `resolveWindowsWrapperToken` up to the path: what `/%~?dp0%?\s*[\\/]*(.*)$/i` captures
    /// from the first place it matches, trimmed, runs of slashes as one backslash and none leading.
    private static func pathAfterScriptDirectory(in token: [UInt16]) -> String? {
        let lineEnds: Set<UInt16> = [0x0A, 0x0D, 0x2028, 0x2029]
        let isSeparator = { (unit: UInt16) in unit == 0x5C || unit == 0x2F }
        for start in token.indices where token[start] == 0x25 {
            var index = start + 1
            if index < token.count, token[index] == 0x7E { index += 1 }
            let name = String(decoding: token[index..<min(index + 3, token.count)], as: UTF16.self)
            guard name.lowercased() == "dp0" else { continue }
            index += 3
            if index < token.count, token[index] == 0x25 { index += 1 }
            while index < token.count, let scalar = Unicode.Scalar(token[index]),
                  TerminalOutputLimit.isJavaScriptWhitespace(scalar) { index += 1 }
            while index < token.count, isSeparator(token[index]) { index += 1 }
            let rest = token[index...]
            guard !rest.contains(where: lineEnds.contains) else { continue }
            let trimmed = Array(TerminalOutputLimit.javaScriptTrimmed(String(decoding: rest, as: UTF16.self)).utf16)
            guard !trimmed.isEmpty else { return nil }
            var collapsed: [UInt16] = []
            for unit in trimmed {
                if isSeparator(unit) {
                    if collapsed.last != 0x5C { collapsed.append(0x5C) }
                } else {
                    collapsed.append(unit)
                }
            }
            if collapsed.first == 0x5C { collapsed.removeFirst() }
            return String(decoding: collapsed, as: UTF16.self)
        }
        return nil
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

    // MARK: - Terminals

    /// A terminal's command on Windows, as acpx starts it (`buildTerminalSpawnCommand`,
    /// `buildTerminalSpawnOptions`): as it is, unless it names a `.cmd` or `.bat`, which acpx gives
    /// Node's `shell: true` (`buildSpawnCommandOptions`). Node then runs `shell`, its own
    /// `%COMSPEC%` (cmd.exe without one), as `/d /s /c "<command> <arguments>"`, the words joined by
    /// spaces and passed as they are; a shell that is not cmd.exe gets `-c` and the line (#272).
    static func terminal(
        command: String, arguments: [String], environment: [String: String], cwd: String,
        fileSystem: FileSystem, shell: String?
    ) -> WindowsSpawnCommand {
        let resolved = resolve(command, environment: environment, cwd: cwd, fileSystem: fileSystem) ?? command
        let extensionName = WindowsPath.extname(resolved).lowercased()
        guard extensionName == ".cmd" || extensionName == ".bat" else {
            return WindowsSpawnCommand(command: command, arguments: arguments)
        }
        let file = shell.flatMap { $0.isEmpty ? nil : $0 } ?? "cmd.exe"
        let line = ([command] + arguments).joined(separator: " ")
        guard isCmd(file) else { return WindowsSpawnCommand(command: file, arguments: ["-c", line]) }
        return WindowsSpawnCommand(command: file, arguments: ["/d", "/s", "/c", "\"\(line)\""], verbatimArguments: true)
    }

    /// Node's `/^(?:.*\\)?cmd(?:\.exe)?$/i`: cmd.exe, by the name after the last backslash, with no
    /// line break before it (a slash is no separator here).
    private static func isCmd(_ shell: String) -> Bool {
        let parts = shell.unicodeScalars.split(separator: "\\", omittingEmptySubsequences: false)
        guard let name = parts.last, ["cmd", "cmd.exe"].contains(String(name).lowercased()) else { return false }
        return !parts.dropLast().joined().contains { ["\n", "\r", "\u{2028}", "\u{2029}"].contains($0) }
    }

    /// acpx's `buildTerminalFallbackSpawnCommand` on `win32`, for a command that was not found: the
    /// line through `cmd.exe /d /s /c`, unless it is a path that is there, or has none of
    /// `hasWindowsShellSyntax`'s characters and no whitespace. A relative `cwd` is taken from
    /// `processDirectory`, as Node's `path.resolve` takes it from `process.cwd()`.
    static func terminalFallback(
        _ command: String, cwd: String, fileSystem: FileSystem,
        processDirectory: String = FileManager.default.currentDirectoryPath
    ) -> WindowsSpawnCommand? {
        if command.utf16.contains(where: WindowsPath.isSeparator) {
            let path = WindowsPath.isAbsolute(command)
                ? command : WindowsPath.resolve([cwd, command], processDirectory: processDirectory)
            if fileSystem.exists(path) { return nil }
        }
        let readsAsLine = command.unicodeScalars.contains {
            windowsShellSyntax.contains($0) || TerminalOutputLimit.isJavaScriptWhitespace($0)
        }
        return readsAsLine ? WindowsSpawnCommand(command: "cmd.exe", arguments: ["/d", "/s", "/c", command]) : nil
    }

    /// acpx's `hasWindowsShellSyntax`: `[|&;<>()>$\`*?[\]{}'"\r\n]`, a backslash not among them.
    private static let windowsShellSyntax = Set("|&;<>()$`*?[]{}'\"\r\n".unicodeScalars)

    /// acpx's `toEnvObject` as its Windows lookups (`readWindowsEnvValue`) read it: `variables` laid
    /// over `parent` in turn. A name that differs only in case from one before it is a variable of its
    /// own, after that one, where a lookup, which takes the first, never finds it.
    static func lookupEnvironment(
        _ variables: [(name: String, value: String)], over parent: [String: String]
    ) -> [String: String] {
        var merged = parent
        var names = Set(parent.keys.map { $0.uppercased() })
        for variable in variables {
            guard merged[variable.name] != nil || names.insert(variable.name.uppercased()).inserted else { continue }
            merged[variable.name] = variable.value
        }
        return merged
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

    /// acpx's `escapeCmdArgument`, cross-spawn's rule: each run of backslashes before a quote
    /// doubled and the quote escaped, a run at the end doubled, the whole quoted, and each
    /// metacharacter escaped — twice for a `node_modules\.bin` shim, which cmd.exe reads a second
    /// time. The runs are doubled whole, as acpx 0.19.4's `escapeBackslashesForQuoting` doubles them
    /// in one pass over the code points; 0.19.3's lookahead doubled only each run's last backslash
    /// (openclaw/acpx#830).
    static func escapeArgument(_ argument: String, doubleEscape: Bool) -> String {
        var doubled = String.UnicodeScalarView()
        var backslashes = 0
        for scalar in argument.unicodeScalars {
            if scalar == "\\" {
                backslashes += 1
                continue
            }
            let count = scalar == "\"" ? backslashes * 2 + 1 : backslashes
            doubled.append(contentsOf: repeatElement("\\", count: count))
            doubled.append(scalar)
            backslashes = 0
        }
        doubled.append(contentsOf: repeatElement("\\", count: backslashes * 2))
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
