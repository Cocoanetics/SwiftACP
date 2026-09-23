import Foundation

/// One commander option: its long and short flags, whether it takes a value, and
/// what commander does with that value.
///
/// A `--no-<x>` option is spelled that way (`OptionSpec("no-fs")`): commander defines
/// only the negated form, so `--fs` is unknown.
struct OptionSpec {
    let long: String
    let short: Character?
    let takesValue: Bool
    let repeats: Bool
    /// The value placeholder in the commander help term — `path` in
    /// `-f, --file <path>`. Not derivable from the name, so it is given here.
    let value: String?
    /// Where the value is kept: commander's attribute name, the long name unless the
    /// option declares another (`sessions export --cwd` keeps `sourceCwd`, so the root's
    /// `--cwd` does not overwrite it).
    let key: String
    /// `requiredOption`: the command refuses to run without it.
    let mandatory: Bool
    /// The option's `parseArg`, which commander runs on each value as it parses it.
    /// It throws the bare reason; the parse frames it with the option's term.
    let validate: (@Sendable (String) throws -> Void)?

    init(
        _ long: String, short: Character? = nil, takesValue: Bool = false, repeats: Bool = false,
        value: String? = nil, key: String? = nil, mandatory: Bool = false,
        validate: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.long = long
        self.short = short
        self.takesValue = takesValue
        self.repeats = repeats
        self.value = value
        self.key = key ?? long
        self.mandatory = mandatory
        self.validate = validate
    }

    /// commander's help term: what `--help` lists and what a parse error names,
    /// e.g. `-f, --file <path>`, `--config-option <key=value>`, `--verbose`.
    var term: String {
        let flags = short.map { "-\($0), --\(long)" } ?? "--\(long)"
        return value.map { "\(flags) <\($0)>" } ?? flags
    }

    /// commander's `Option.is(arg)`: the exact short or long flag.
    func matches(_ arg: String) -> Bool {
        arg == "--\(long)" || short.map { arg == "-\($0)" } == true
    }
}

/// The options given to a command, by key (see ``OptionSpec/key``).
struct ScannedArgs {
    /// Key → value (value options) or "true" (boolean flags present).
    var values: [String: String] = [:]
    /// Every occurrence of a repeatable option, in the order given on the command line.
    var repeated: [String: [String]] = [:]
    /// The specs these options were given against, so a rejected value can be framed
    /// with the option's commander term without the call site repeating it.
    var specs: [String: OptionSpec] = [:]

    func string(_ name: String) -> String? { values[name] }
    /// Every value given for a repeatable option, in command-line order.
    func strings(_ name: String) -> [String] { repeated[name] ?? [] }
    func flag(_ name: String) -> Bool { values[name] == "true" }

    /// commander's term for a scanned option, e.g. `-f, --file <path>`.
    func term(_ name: String) -> String { specs[name]?.term ?? "--\(name)" }

    /// Read a value option and run it through `parse`, framing a rejection the way
    /// commander does: `option '<term>' argument '<value>' is invalid. <reason>`.
    /// The parser throws the bare reason; only the scan knows which option it came from.
    func parsed<T>(_ name: String, _ parse: (String) throws -> T) throws -> T? {
        guard let raw = values[name] else { return nil }
        do {
            return try parse(raw)
        } catch let error as UsageError {
            throw UsageError.invalidArgument(term(name), raw, error.message)
        }
    }

    /// The repeatable form of ``parsed(_:_:)``.
    func parsedAll<T>(_ name: String, _ parse: (String) throws -> T) throws -> [T] {
        try strings(name).map { raw in
            do {
                return try parse(raw)
            } catch let error as UsageError {
                throw UsageError.invalidArgument(term(name), raw, error.message)
            }
        }
    }

    /// Store one occurrence of a value option: last-wins for `string`, and also
    /// accumulated in order when the option is repeatable.
    mutating func record(_ spec: OptionSpec, _ value: String) {
        specs[spec.key] = spec
        values[spec.key] = value
        if spec.repeats { repeated[spec.key, default: []].append(value) }
    }

    /// A boolean option was given.
    mutating func record(_ spec: OptionSpec) {
        specs[spec.key] = spec
        values[spec.key] = "true"
    }

    /// Whether the option under `key` was given at all.
    func has(_ key: String) -> Bool { values[key] != nil }
}
