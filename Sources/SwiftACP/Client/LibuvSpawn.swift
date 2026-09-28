import Foundation

/// How Node's libuv starts a process on Windows (`uv_spawn`, `src/win/process.c`), for a launch
/// probe (#265). It finds the file as `search_path` does, and builds the command line as
/// `make_program_args` does and the environment block as `make_program_env` does. It looks only
/// at the file system it is given, so it is checked on every platform.
enum LibuvSpawn {
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let quote = UInt16(UInt8(ascii: "\""))
    private static let apostrophe = UInt16(UInt8(ascii: "'"))
    private static let semicolon = UInt16(UInt8(ascii: ";"))

    // MARK: - search_path

    /// `search_path`: `file` itself if it has a directory; otherwise first in `cwd` (while
    /// `searchesCurrentDirectory`, Windows' `NeedCurrentDirectoryForExePathW`), then in each of
    /// `path`'s directories. In each place, a name with an extension is tried as it is, then with
    /// `.com` and `.exe` appended. `PATHEXT`'s other extensions are never tried: `CreateProcess`
    /// starts only those two.
    static func searchPath(
        _ file: String, cwd: String, path: String?, searchesCurrentDirectory: Bool,
        isFile: (String) -> Bool
    ) -> String? {
        let file = Array(file.utf16)
        let cwd = Array(cwd.utf16)
        guard !file.isEmpty, file != [dot] else { return nil }
        let nameStart = (file.lastIndex { $0 == backslash || $0 == slash || $0 == colon } ?? -1) + 1
        let name = Array(file[nameStart...])
        // An extension: a dot in the name that is not its last character.
        let hasExtension = name.firstIndex(of: dot).map { $0 < name.count - 1 } ?? false
        if nameStart > 0 {
            return tryExtensions(in: Array(file[..<nameStart]), name, cwd: cwd, hasExtension, isFile)
        }
        if searchesCurrentDirectory, let found = tryExtensions(in: [], file, cwd: cwd, hasExtension, isFile) {
            return found
        }
        for directory in pathDirectories(path) {
            if let found = tryExtensions(in: directory, file, cwd: cwd, hasExtension, isFile) { return found }
        }
        return nil
    }

    /// `path_search_walk_ext`.
    private static func tryExtensions(
        in directory: [UInt16], _ name: [UInt16], cwd: [UInt16], _ hasExtension: Bool, _ isFile: (String) -> Bool
    ) -> String? {
        let extensions: [[UInt16]] = (hasExtension ? [[]] : []) + [Array("com".utf16), Array("exe".utf16)]
        for fileExtension in extensions {
            let candidate = joined(directory, name, fileExtension, cwd: cwd)
            if isFile(candidate) { return candidate }
        }
        return nil
    }

    /// `search_path_join_test`'s path: `cwd` for a relative directory, its drive for one from a
    /// root, nothing for a UNC or drive path; then the directory, the name and the extension.
    private static func joined(
        _ directory: [UInt16], _ name: [UInt16], _ fileExtension: [UInt16], cwd: [UInt16]
    ) -> String {
        var directory = directory[...]
        var cwdLength = cwd.count
        let isSeparator = { (unit: UInt16) in unit == backslash || unit == slash }
        if directory.count > 2, isSeparator(directory[0]), isSeparator(directory[1]) {
            cwdLength = 0
        } else if let first = directory.first, isSeparator(first) {
            cwdLength = 2
        } else if directory.count >= 2, directory[1] == colon, directory.count < 3 || !isSeparator(directory[2]) {
            // Relative on a drive: from `cwd` if it is on that drive.
            let sameDrive = cwdLength >= 2
                && String(decoding: cwd.prefix(2), as: UTF16.self).lowercased()
                == String(decoding: directory.prefix(2), as: UTF16.self).lowercased()
            if sameDrive { directory = directory.dropFirst(2) } else { cwdLength = 0 }
        } else if directory.count > 2, directory[1] == colon {
            cwdLength = 0
        }
        let ends = [backslash, slash, colon]
        var path = Array(cwd.prefix(cwdLength))
        if let last = path.last, !ends.contains(last) { path.append(backslash) }
        path += directory
        if !directory.isEmpty, let last = path.last, !ends.contains(last) { path.append(backslash) }
        path += name
        if !fileExtension.isEmpty {
            if !name.isEmpty, path.last != dot { path.append(dot) }
            path += fileExtension
        }
        return String(decoding: path, as: UTF16.self)
    }

    /// `search_path`'s walk of `PATH`: `;`-separated directories, a quoted one (`"` or `'`)
    /// running to its closing quote, and the quotes dropped. Empty ones are skipped.
    private static func pathDirectories(_ path: String?) -> [[UInt16]] {
        guard let path else { return [] }
        let units = Array(path.utf16)
        var directories: [[UInt16]] = []
        var end = 0
        while end < units.count {
            if end != 0 || units[0] == semicolon { end += 1 }
            let start = end
            var searchFrom = start
            if start < units.count, units[start] == quote || units[start] == apostrophe {
                searchFrom = units[(start + 1)...].firstIndex(of: units[start]) ?? units.count
            }
            end = units[searchFrom...].firstIndex(of: semicolon) ?? units.count
            guard end > start else { continue }
            var directory = Array(units[start..<end])
            if directory[0] == quote || directory[0] == apostrophe { directory.removeFirst() }
            if let last = directory.last, last == quote || last == apostrophe { directory.removeLast() }
            if !directory.isEmpty { directories.append(directory) }
        }
        return directories
    }

    // MARK: - The command line

    /// `make_program_args`: `arguments`, the program's own name first, each quoted as
    /// `quote_cmd_arg` quotes it (or as they are, `verbatim`), a space between each.
    static func commandLine(_ arguments: [String], verbatim: Bool) -> String {
        arguments.map { verbatim ? $0 : quoted($0) }.joined(separator: " ")
    }

    /// `quote_cmd_arg`: quoted when it has a space, a tab or a quote, with a quote and the
    /// backslashes before it, or those at the end, escaped for the C runtime's parser.
    static func quoted(_ argument: String) -> String {
        let units = Array(argument.utf16)
        guard !units.isEmpty else { return "\"\"" }
        guard units.contains(where: { $0 == 0x20 || $0 == 0x09 || $0 == quote }) else { return argument }
        guard units.contains(where: { $0 == quote || $0 == backslash }) else { return "\"" + argument + "\"" }
        // Built back to front, as libuv builds it: a backslash is doubled while it runs up to a
        // quote or the end, and a quote gets a backslash.
        var reversed: [UInt16] = []
        var quoteHit = true
        for unit in units.reversed() {
            reversed.append(unit)
            if quoteHit, unit == backslash {
                reversed.append(backslash)
            } else if unit == quote {
                quoteHit = true
                reversed.append(backslash)
            } else {
                quoteHit = false
            }
        }
        return "\"" + String(decoding: reversed.reversed(), as: UTF16.self) + "\""
    }

    // MARK: - The environment block

    /// `make_program_env`'s `required_vars`: what Windows programs need, taken from the parent
    /// when the environment lacks them.
    private static let requiredVariables = [
        "HOMEDRIVE", "HOMEPATH", "LOGONSERVER", "PATH", "SYSTEMDRIVE", "SYSTEMROOT", "TEMP",
        "USERDOMAIN", "USERNAME", "USERPROFILE", "WINDIR"
    ]

    /// The block `CreateProcessW` takes, as Node and libuv build it from `environment`. Node keeps
    /// one spelling of each name, the first in code-unit order. libuv sorts the variables by name
    /// in any case, and adds those Windows needs from `parent` when they are missing. Each ends in
    /// a NUL, and the block in one more.
    static func environmentBlock(_ environment: [String: String], parent: [String: String]) -> [UInt16] {
        var names = Set<String>()
        var variables: [(name: String, entry: String)] = []
        for key in environment.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) })
        where names.insert(key.uppercased()).inserted {
            variables.append((key.uppercased(), key + "=" + (environment[key] ?? "")))
        }
        for name in requiredVariables where !names.contains(name) {
            if let value = WindowsSpawnCommand.value(of: name, in: parent) {
                variables.append((name, name + "=" + value))
            }
        }
        variables.sort { $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) }
        return variables.flatMap { Array($0.entry.utf16) + [0] } + [0]
    }
}
