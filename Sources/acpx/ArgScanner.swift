import Foundation

/// One option definition (long/short, whether it takes a value, negatable,
/// repeatable). A repeatable option keeps every occurrence in order — commander's
/// collecting options (`--config-option`) rather than its default last-wins.
struct OptionSpec {
    let long: String
    let short: Character?
    let takesValue: Bool
    let negatable: Bool
    let repeats: Bool
    /// The value placeholder in the commander help term — `path` in
    /// `-f, --file <path>`. Not derivable from the name, so it is given here.
    let value: String?

    init(
        _ long: String, short: Character? = nil, takesValue: Bool = false,
        negatable: Bool = false, repeats: Bool = false, value: String? = nil
    ) {
        self.long = long
        self.short = short
        self.takesValue = takesValue
        self.negatable = negatable
        self.repeats = repeats
        self.value = value
    }

    /// commander's help term: what `--help` lists and what a parse error names,
    /// e.g. `-f, --file <path>`, `--config-option <key=value>`, `--verbose`.
    var term: String {
        let flags = short.map { "-\($0), --\(long)" } ?? "--\(long)"
        return value.map { "\(flags) <\($0)>" } ?? flags
    }
}

/// The result of scanning argv against a set of option specs.
struct ScannedArgs {
    /// Long-name → value (value options) or "true" (boolean flags present).
    var values: [String: String] = [:]
    /// Long-names explicitly negated via `--no-<name>`.
    var negated: Set<String> = []
    /// Every occurrence of a repeatable option, in the order given on the command line.
    var repeated: [String: [String]] = [:]
    var positionals: [String] = []
    /// The specs this argv was scanned against, so a rejected value can be framed
    /// with the option's commander term without the call site repeating it.
    fileprivate var specs: [String: OptionSpec] = [:]

    func string(_ name: String) -> String? { values[name] }
    /// Every value given for a repeatable option, in command-line order.
    func strings(_ name: String) -> [String] { repeated[name] ?? [] }
    func flag(_ name: String) -> Bool { values[name] == "true" }
    /// Tri-state for negatable booleans: true (present), false (--no-x), nil (absent).
    func boolean(_ name: String) -> Bool? {
        if values[name] == "true" { return true }
        if negated.contains(name) { return false }
        return nil
    }

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

    /// Consume one option occurrence: an inline or packed value, else the next
    /// argument, else (unless lenient) commander's "argument missing".
    fileprivate mutating func take(
        _ spec: OptionSpec, inline: String?, from args: [String], at index: inout Int,
        lenient: Bool
    ) throws {
        guard spec.takesValue else {
            values[spec.long] = "true"
            return
        }
        if let inline {
            record(spec, inline)
        } else if index < args.count {
            record(spec, args[index])
            index += 1
        } else if !lenient {
            throw UsageError.argumentMissing(spec.term)
        }
    }

    /// Store one occurrence of a value option: last-wins for `string`, and also
    /// accumulated in order when the option is repeatable.
    fileprivate mutating func record(_ spec: OptionSpec, _ value: String) {
        values[spec.long] = value
        if spec.repeats { repeated[spec.long, default: []].append(value) }
    }
}

/// A commander-like scanner: options may be interspersed with positionals;
/// `--` stops option parsing.
enum ArgScanner {
    /// Scan `args` against `specs`.
    ///
    /// `lenient` is for the routing pre-pass, whose only job is to recover the
    /// positional command path: it skips an unrecognized option (and a missing
    /// argument) instead of throwing, so the error comes from the command's own
    /// scan — which knows the path, and so can show the right help. commander
    /// reports these against the resolved command for the same reason.
    static func scan(
        _ args: [String], options specs: [OptionSpec], lenient: Bool = false
    ) throws -> ScannedArgs {
        var result = ScannedArgs()
        let byLong = Dictionary(specs.map { ($0.long, $0) }, uniquingKeysWith: { first, _ in first })
        result.specs = byLong
        var byShort: [Character: OptionSpec] = [:]
        for spec in specs { if let s = spec.short { byShort[s] = spec } }

        var index = 0
        var optionsDone = false
        while index < args.count {
            let token = args[index]
            index += 1

            if optionsDone {
                result.positionals.append(token)
                continue
            }
            if token == "--" {
                optionsDone = true
                continue
            }

            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let (name, inlineValue) = splitEquals(body)
                if name.hasPrefix("no-"), let spec = byLong[String(name.dropFirst(3))], spec.negatable {
                    result.negated.insert(spec.long)
                    continue
                }
                guard let spec = byLong[name] else {
                    if lenient { continue }
                    throw UsageError("unknown option '--\(name)'")
                }
                try result.take(
                    spec, inline: inlineValue, from: args, at: &index, lenient: lenient)
            } else if token.hasPrefix("-") && token.count > 1 {
                let body = String(token.dropFirst())
                let (flag, inlineValue) = splitEquals(body)
                guard let first = flag.first, let spec = byShort[first] else {
                    if lenient { continue }
                    throw UsageError("unknown option '\(token)'")
                }
                // `-sname` packs the value onto the flag, commander-style.
                let packed = flag.count > 1 ? String(flag.dropFirst()) : nil
                try result.take(
                    spec, inline: inlineValue ?? packed, from: args, at: &index, lenient: lenient)
            } else {
                result.positionals.append(token)
            }
        }
        return result
    }

    private static func splitEquals(_ body: String) -> (String, String?) {
        if let eq = body.firstIndex(of: "=") {
            return (String(body[..<eq]), String(body[body.index(after: eq)...]))
        }
        return (body, nil)
    }
}
