import Foundation

/// commander 15's parse of a command line — `parseOptions` and `_parseCommand` — for
/// acpx's program (``CommandTree``).
///
/// Every command has positional options, so a command's options come before its
/// subcommand, and an option placed after it belongs to the subcommand or is unknown
/// there. The agent commands also pass everything after their first operand through,
/// so a prompt may contain flags. An error names the command whose parse raised it:
/// the root's are acpx's usage errors (exit 2); a subcommand's exit 1.
enum Commander {
    /// A command on the parsed path, with the options given to it.
    struct Level {
        let spec: CommandSpec
        var options = ScannedArgs()
        /// The options as commander emits them, in command-line order: each
        /// `option:<name>` event with its raw value (none for a flag).
        var events: [(name: String, value: String?)] = []
    }

    /// What the command line asks for.
    enum Outcome {
        /// Run the last command of `levels` with `arguments`.
        case run(levels: [Level], arguments: [String])
        /// Print the help for `path` (below the root) and succeed: `-h`/`--help`, or
        /// `flow help <command>`.
        case help(path: [String])
        /// Print the help for `path` as an error: `flow` with nothing to run.
        case helpAsError(path: [String])
        /// The root's `help` given a name that is no command: its help as an error, then
        /// commander's `(outputHelp)` through acpx's handler, as a usage error.
        case helpCommandMisuse(path: [String])
        /// `-V`/`--version`, which commander answers as soon as it parses it.
        case version
    }

    static func parse(_ args: [String], root: CommandSpec) throws -> Outcome {
        do {
            return try parseCommand(root, path: [], ancestors: [], operands: [], unknown: args)
        } catch is VersionRequested {
            return .version
        }
    }

    private struct VersionRequested: Error {}

    // MARK: - _parseCommand

    private static func parseCommand(
        _ spec: CommandSpec, path: [String], ancestors: [Level], operands given: [String], unknown rest: [String]
    ) throws -> Outcome {
        let isRoot = ancestors.isEmpty
        let fail = { (message: String) in
            UsageError(message, scope: isRoot ? .root : .command, path: path)
        }
        var level = Level(spec: spec)
        let parsed = try parseOptions(rest, into: &level, isRoot: isRoot, fail: fail)
        let operands = given + parsed.operands
        let unknown = parsed.unknown
        let args = operands + unknown
        let levels = ancestors + [level]

        if let first = operands.first, let subcommand = spec.subcommand(first) {
            return try parseCommand(
                subcommand, path: path + [first], ancestors: levels, operands: Array(operands.dropFirst()),
                unknown: unknown)
        }
        if spec.hasHelpCommand, operands.first == "help" {
            // `_dispatchHelpCommand`: the named subcommand's help; for a name that is not
            // one, this command's help as an error.
            guard operands.count > 1 else { return .help(path: path) }
            if spec.subcommand(operands[1]) != nil { return .help(path: path + [operands[1]]) }
            // The root exits through acpx's handler (`handleProgramParseError`); `flow`,
            // through commander's own.
            return isRoot ? .helpCommandMisuse(path: path) : .helpAsError(path: path)
        }
        if !spec.subcommands.isEmpty, args.isEmpty, !spec.hasAction {
            return .helpAsError(path: path)
        }
        if unknown.contains(where: { $0 == "-h" || $0 == "--help" }) {
            return .help(path: path)
        }
        try checkMandatoryOptions(levels, path: path)
        if spec.hasAction {
            if let option = unknown.first { throw fail(unknownOption(option, of: spec)) }
            return .run(levels: levels, arguments: try processArguments(args, of: spec, isRoot: isRoot, fail: fail))
        }
        if let first = operands.first { throw fail(unknownCommand(first, of: spec)) }
        if let option = unknown.first { throw fail(unknownOption(option, of: spec)) }
        return .helpAsError(path: path)
    }

    /// `_checkForMissingMandatoryOptions`: the command's and its ancestors' required
    /// options, each refused by the command that declares it.
    private static func checkMandatoryOptions(_ levels: [Level], path: [String]) throws {
        for (depth, level) in levels.enumerated().reversed() {
            for option in level.spec.options where option.mandatory && !level.options.has(option.key) {
                let levelPath = Array(path.prefix(depth))
                throw UsageError(
                    "required option '\(option.term)' not specified", scope: depth == 0 ? .root : .command,
                    path: levelPath)
            }
        }
    }

    /// `_processArguments`: too few, too many, then each argument's parser.
    private static func processArguments(
        _ args: [String], of spec: CommandSpec, isRoot: Bool, fail: (String) -> UsageError
    ) throws -> [String] {
        for (index, argument) in spec.arguments.enumerated() where argument.required && index >= args.count {
            throw fail("missing required argument '\(argument.name)'")
        }
        if spec.arguments.last?.variadic != true, args.count > spec.arguments.count {
            let expected = spec.arguments.count
            let noun = expected == 1 ? "argument" : "arguments"
            let forCommand = isRoot ? "" : " for '\(spec.name)'"
            throw fail(
                "too many arguments\(forCommand). Expected \(expected) \(noun) but got \(args.count): "
                    + "\(args.joined(separator: ", ")).")
        }
        for (index, argument) in spec.arguments.enumerated() {
            guard let validate = argument.validate else { continue }
            let values = argument.variadic ? Array(args.dropFirst(index)) : (index < args.count ? [args[index]] : [])
            for value in values {
                do {
                    try validate(value)
                } catch let error as UsageError {
                    throw fail(
                        "command-argument value '\(value)' is invalid for argument '\(argument.name)'. "
                            + error.message)
                }
            }
        }
        return args
    }

    // MARK: - parseOptions

    private struct Parsed {
        var operands: [String] = []
        /// The first unknown option and everything after it.
        var unknown: [String] = []
    }

    private static func parseOptions(
        _ args: [String], into level: inout Level, isRoot: Bool, fail: (String) -> UsageError
    ) throws -> Parsed {
        let spec = level.spec
        var parsed = Parsed()
        var toUnknown = false
        func place<S: Sequence<String>>(_ items: S) {
            if toUnknown { parsed.unknown += items } else { parsed.operands += items }
        }
        var index = 0
        var group: String?
        while index < args.count || group != nil {
            let arg: String
            if let pending = group {
                arg = pending
                group = nil
            } else {
                arg = args[index]
                index += 1
            }

            if arg == "--" {
                if toUnknown { parsed.unknown.append(arg) }
                place(args[index...])
                break
            }
            if isOptionLike(arg), let option = spec.option(matching: arg) {
                if option.takesValue {
                    guard index < args.count else { throw fail("option '\(option.term)' argument missing") }
                    try give(option, args[index], to: &level, fail: fail)
                    index += 1
                } else {
                    try set(option, on: &level, isRoot: isRoot)
                }
                continue
            }
            // A group of short options, `-ab`, or a short option with its value, `-sname`.
            if arg.utf16.count > 2, arg.hasPrefix("-"), !arg.hasPrefix("--"),
                let option = spec.option(matching: String(arg.prefix(2))) {
                if option.takesValue {
                    try give(option, String(arg.dropFirst(2)), to: &level, fail: fail)
                } else {
                    try set(option, on: &level, isRoot: isRoot)
                    group = "-" + arg.dropFirst(2)
                }
                continue
            }
            // A long option with its value, `--name=value`.
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "="),
                equals > arg.index(arg.startIndex, offsetBy: 2),
                let option = spec.option(matching: String(arg[..<equals])), option.takesValue {
                try give(option, String(arg[arg.index(after: equals)...]), to: &level, fail: fail)
                continue
            }

            // Not this command's option: a subcommand, an operand, or unknown — and once
            // an option is unknown, so is the rest, for a subcommand to parse again.
            if !toUnknown, isOptionLike(arg), !(spec.subcommands.isEmpty && isNegativeNumber(arg)) {
                toUnknown = true
            }
            // Positional options: this command's options end at its subcommand.
            if parsed.operands.isEmpty, parsed.unknown.isEmpty {
                if spec.subcommand(arg) != nil {
                    parsed.operands.append(arg)
                    parsed.unknown += args[index...]
                    break
                }
                if spec.hasHelpCommand, arg == "help" {
                    parsed.operands.append(arg)
                    parsed.operands += args[index...]
                    break
                }
            }
            if spec.passThrough {
                place(CollectionOfOne(arg))
                place(args[index...])
                break
            }
            place(CollectionOfOne(arg))
        }
        return parsed
    }

    /// A value option's occurrence: its parser first, which may refuse it.
    private static func give(
        _ option: OptionSpec, _ value: String, to level: inout Level, fail: (String) -> UsageError
    ) throws {
        if let validate = option.validate {
            do {
                try validate(value)
            } catch let error as UsageError {
                throw fail("option '\(option.term)' argument '\(value)' is invalid. \(error.message)")
            }
        }
        level.options.record(option, value)
        level.events.append((option.long, value))
    }

    private static func set(_ option: OptionSpec, on level: inout Level, isRoot: Bool) throws {
        if isRoot, option.long == CommandTree.versionOption.long { throw VersionRequested() }
        level.options.record(option)
        level.events.append((option.long, nil))
    }

    /// commander's `maybeOption`.
    private static func isOptionLike(_ arg: String) -> Bool {
        arg.utf16.count > 1 && arg.hasPrefix("-")
    }

    /// commander's `negativeNumberArg`: `/^-(\d+|\d*\.\d+)(e[+-]?\d+)?$/`, which a
    /// command without subcommands takes as an operand.
    static func isNegativeNumber(_ arg: String) -> Bool {
        var rest = Substring(arg)
        guard rest.popFirst() == "-" else { return false }
        func digits() -> Int {
            var count = 0
            while let next = rest.first, next.isASCII, next.isNumber {
                rest.removeFirst()
                count += 1
            }
            return count
        }
        let whole = digits()
        if rest.first == "." {
            rest.removeFirst()
            guard digits() > 0 else { return false }
        } else if whole == 0 {
            return false
        }
        if rest.first == "e" {
            rest.removeFirst()
            if rest.first == "+" || rest.first == "-" { rest.removeFirst() }
            guard digits() > 0 else { return false }
        }
        return rest.isEmpty
    }

    // MARK: - Messages

    /// `unknownOption`: with a suggestion from the command's own options (every acpx
    /// command has positional options, so its parent's are not candidates).
    private static func unknownOption(_ flag: String, of spec: CommandSpec) -> String {
        var suggestion = ""
        if flag.hasPrefix("--") {
            suggestion = suggestSimilar(flag, spec.options.map { "--\($0.long)" } + ["--help"])
        }
        return "unknown option '\(flag)'\(suggestion)"
    }

    private static func unknownCommand(_ name: String, of spec: CommandSpec) -> String {
        let candidates = spec.subcommands.map(\.name) + (spec.hasHelpCommand ? ["help"] : [])
        return "unknown command '\(name)'\(suggestSimilar(name, candidates))"
    }

    /// commander's `suggestSimilar`: the candidates within the fewest edits (at most
    /// three) that still share more than 40% of the word.
    static func suggestSimilar(_ word: String, _ candidates: [String]) -> String {
        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        guard !unique.isEmpty else { return "" }
        let searchingOptions = word.hasPrefix("--")
        let target = searchingOptions ? String(word.dropFirst(2)) : word
        let names = searchingOptions ? unique.map { String($0.dropFirst(2)) } : unique

        var similar: [String] = []
        var bestDistance = maxDistance
        for candidate in names where candidate.utf16.count > 1 {
            let distance = editDistance(Array(target.utf16), Array(candidate.utf16))
            let length = max(target.utf16.count, candidate.utf16.count)
            guard Double(length - distance) / Double(length) > 0.4 else { continue }
            if distance < bestDistance {
                bestDistance = distance
                similar = [candidate]
            } else if distance == bestDistance {
                similar.append(candidate)
            }
        }
        similar.sort { $0.compare($1, locale: Locale(identifier: "en")) == .orderedAscending }
        if searchingOptions { similar = similar.map { "--" + $0 } }
        if similar.count > 1 { return "\n(Did you mean one of \(similar.joined(separator: ", "))?)" }
        if let only = similar.first { return "\n(Did you mean \(only)?)" }
        return ""
    }

    private static let maxDistance = 3

    /// The optimal string alignment distance, over UTF-16 code units as JavaScript has it.
    private static func editDistance(_ lhs: [UInt16], _ rhs: [UInt16]) -> Int {
        if abs(lhs.count - rhs.count) > maxDistance { return max(lhs.count, rhs.count) }
        var distance = [[Int]](repeating: [Int](repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for row in 0...lhs.count { distance[row][0] = row }
        for column in 0...rhs.count { distance[0][column] = column }
        guard !lhs.isEmpty, !rhs.isEmpty else { return distance[lhs.count][rhs.count] }
        for column in 1...rhs.count {
            for row in 1...lhs.count {
                let cost = lhs[row - 1] == rhs[column - 1] ? 0 : 1
                distance[row][column] = min(
                    distance[row - 1][column] + 1, distance[row][column - 1] + 1,
                    distance[row - 1][column - 1] + cost)
                if row > 1, column > 1, lhs[row - 1] == rhs[column - 2], lhs[row - 2] == rhs[column - 1] {
                    distance[row][column] = min(distance[row][column], distance[row - 2][column - 2] + 1)
                }
            }
        }
        return distance[lhs.count][rhs.count]
    }
}
