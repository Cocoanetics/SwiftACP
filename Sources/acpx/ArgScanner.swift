import Foundation

/// One option definition (long/short, whether it takes a value, negatable).
struct OptionSpec {
    let long: String
    let short: Character?
    let takesValue: Bool
    let negatable: Bool

    init(_ long: String, short: Character? = nil, takesValue: Bool = false, negatable: Bool = false) {
        self.long = long
        self.short = short
        self.takesValue = takesValue
        self.negatable = negatable
    }
}

/// The result of scanning argv against a set of option specs.
struct ScannedArgs {
    /// Long-name → value (value options) or "true" (boolean flags present).
    var values: [String: String] = [:]
    /// Long-names explicitly negated via `--no-<name>`.
    var negated: Set<String> = []
    var positionals: [String] = []

    func string(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { values[name] == "true" }
    /// Tri-state for negatable booleans: true (present), false (--no-x), nil (absent).
    func boolean(_ name: String) -> Bool? {
        if values[name] == "true" { return true }
        if negated.contains(name) { return false }
        return nil
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
                        result.values[spec.long] = inlineValue
                    } else if index < args.count {
                        result.values[spec.long] = args[index]
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
                        result.values[spec.long] = inlineValue
                    } else if flag.count > 1 {
                        result.values[spec.long] = String(flag.dropFirst())
                    } else if index < args.count {
                        result.values[spec.long] = args[index]
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
