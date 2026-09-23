import ACPXCore
import Foundation

/// acpx's scans of the raw arguments, made before (or without) parsing them: the
/// output format a failure is reported in, and the directory and MCP file the config
/// is loaded from. They read the leading flags — those before the first word that is
/// not a flag — plus, for `compare`, the options after it.
enum LeadingFlags {
    static let outputFormats: Set<String> = ["text", "json", "quiet"]

    /// `TOP_LEVEL_VERSION_VALUE_FLAGS`: the global flags whose value is the next word.
    static let valueFlags = Set(Flags.globalSpecs.filter(\.takesValue).map { "--" + $0.long })

    /// `TOP_LEVEL_VERSION_BOOLEAN_FLAGS`: the global flags the command scan steps over.
    static let booleanFlags: Set<String> = [
        "--approve-all", "--approve-reads", "--deny-all", "--suppress-reads", "--json-strict",
        "--no-fs", "--no-terminal", "--verbose"
    ]

    /// `compare`'s own options that take the next word as their value.
    static let compareValueFlags: Set<String> = [
        "--cwd", "--timeout", "--format", "-f", "--file", "--prompt-file"
    ]

    /// A leading flag and the word after it.
    struct Flag {
        var token: String
        var next: String?
    }

    /// `classifyTopLevelFlagScan`: the leading flags, stopping at `--`, `-` or the
    /// first word that is not a flag, and stepping over a global flag's value.
    static func scan(_ arguments: [String]) -> [Flag] {
        var flags: [Flag] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            guard token != "--", token != "-", token.hasPrefix("-") else { break }
            flags.append(Flag(token: token, next: index + 1 < arguments.count ? arguments[index + 1] : nil))
            index += valueFlags.contains(token) ? 2 : 1
        }
        return flags
    }

    /// The value of `--flag=value` (`token.slice(flag.length + 1)`), or nil.
    static func inlineValue(_ token: String, _ flag: String) -> String? {
        let prefix = (flag + "=").unicodeScalars
        guard token.unicodeScalars.starts(with: prefix) else { return nil }
        return String(token.unicodeScalars.dropFirst(prefix.count))
    }

    /// `lastTopLevelFlagValue`: the value the last leading `flag` was given.
    static func lastValue(_ arguments: [String], _ flag: String) -> String? {
        var value: String?
        for leading in scan(arguments) {
            if leading.token == flag {
                value = leading.next
            } else if let inline = inlineValue(leading.token, flag) {
                value = inline
            }
        }
        return value
    }

    /// `detectRequestedOutputFormat`: json under `--json-strict`, else the last valid
    /// `--format` among the leading flags, weighed against `compare`'s own, else
    /// `fallback`.
    static func requestedFormat(_ arguments: [String], fallback: () -> String) -> String {
        var format: String?
        for leading in scan(arguments) {
            if leading.token == "--json-strict" || leading.token.hasPrefix("--json-strict=") { return "json" }
            // `readFormatFlagValue`: the next word as given, an inline value trimmed.
            let raw = leading.token == "--format"
                ? leading.next : inlineValue(leading.token, "--format")?.javaScriptTrimmed
            if let raw, outputFormats.contains(raw) { format = raw }
        }
        guard let compare = compareOptions(arguments) else { return format ?? fallback() }
        // `detectCompareOutputFormat`: the alias wins, otherwise globals overwrite locals.
        if compare.json { return "json" }
        if let format { return format }
        if let local = compare.format, outputFormats.contains(local) { return local }
        return fallback()
    }

    /// `detectInitialCwd`: where the config is loaded from — `compare`'s own `--cwd`,
    /// else the last leading `--cwd`, else `base` (resolved against `base`).
    static func initialCwd(_ arguments: [String], base: String) -> String {
        if let cwd = compareOptions(arguments)?.cwd {
            return ACPXPaths.resolve(cwd, base: base)
        }
        return ACPXPaths.resolve(lastValue(arguments, "--cwd") ?? base, base: base)
    }

    /// `detectMcpConfigPath`: the last leading `--mcp-config`, when it is not empty.
    static func mcpConfigPath(_ arguments: [String]) -> String? {
        guard let value = lastValue(arguments, "--mcp-config"), !value.isEmpty else { return nil }
        return value
    }

    /// `detectAgentToken`: the first word that is not a flag, and where it is — none
    /// when `--` or a flag the scan does not know comes first.
    static func command(_ arguments: [String]) -> (token: String, index: Int)? {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" { return nil }
            if !token.hasPrefix("-") || token == "-" { return (token, index) }
            if token == "--agent" || valueFlags.contains(token) || token == "--file" {
                index += 2
            } else if booleanFlags.contains(token) || token.hasPrefix("--json-strict=")
                || (valueFlags.union(["--file"])).contains(where: { inlineValue(token, $0) != nil }) {
                index += 1
            } else {
                return nil
            }
        }
        return nil
    }

    /// `compare`'s own output and directory options (`scanCompareArgs`).
    struct CompareOptions {
        var cwd: String?
        var format: String?
        var json = false
    }

    /// `scanCompareArgs` over the words after `compare`, when that is the command; the
    /// scan runs to `--` or the end, stepping over each option's value.
    static func compareOptions(_ arguments: [String]) -> CompareOptions? {
        guard let command = command(arguments), command.token == "compare" else { return nil }
        let rest = Array(arguments[(command.index + 1)...])
        var options = CompareOptions()
        var index = 0
        while index < rest.count {
            let token = rest[index]
            if token == "--" { break }
            let next = index + 1 < rest.count ? rest[index + 1] : nil
            if token == "--cwd" {
                options.cwd = next
            } else if let inline = inlineValue(token, "--cwd") {
                options.cwd = inline
            }
            if token == "--json" {
                options.json = true
            } else if token == "--format" {
                options.format = next
            } else if let inline = inlineValue(token, "--format") {
                options.format = inline
            }
            index += compareValueFlags.contains(token) ? 2 : 1
        }
        return options
    }
}
