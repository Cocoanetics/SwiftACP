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

    init(
        _ long: String, short: Character? = nil, takesValue: Bool = false,
        negatable: Bool = false, repeats: Bool = false
    ) {
        self.long = long
        self.short = short
        self.takesValue = takesValue
        self.negatable = negatable
        self.repeats = repeats
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
    static func scan(_ args: [String], options specs: [OptionSpec]) throws -> ScannedArgs {
        var result = ScannedArgs()
        let byLong = Dictionary(uniqueKeysWithValues: specs.map { ($0.long, $0) })
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
                    throw UsageError("unknown option '--\(name)'")
                }
                if spec.takesValue {
                    if let inlineValue {
                        result.record(spec, inlineValue)
                    } else if index < args.count {
                        result.record(spec, args[index])
                        index += 1
                    } else {
                        throw UsageError("option '--\(spec.long)' argument missing")
                    }
                } else {
                    result.values[spec.long] = "true"
                }
            } else if token.hasPrefix("-") && token.count > 1 {
                let body = String(token.dropFirst())
                let (flag, inlineValue) = splitEquals(body)
                guard let first = flag.first, let spec = byShort[first] else {
                    throw UsageError("unknown option '\(token)'")
                }
                if spec.takesValue {
                    if let inlineValue {
                        result.record(spec, inlineValue)
                    } else if flag.count > 1 {
                        result.record(spec, String(flag.dropFirst()))
                    } else if index < args.count {
                        result.record(spec, args[index])
                        index += 1
                    } else {
                        throw UsageError("option '-\(first)' argument missing")
                    }
                } else {
                    result.values[spec.long] = "true"
                }
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
