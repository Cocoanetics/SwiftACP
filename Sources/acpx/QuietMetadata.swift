import ACPXCore
import Foundation

/// What acpx's quiet formatter writes to stderr after a turn's reply
/// (`QuietOutputFormatter.flushMetadata`): the prompt response's token usage and its
/// cost, each only when present.
enum QuietMetadata {
    /// acpx's `formatUsageLine`: `[acpx] tokens: input=… output=… cache_read=…
    /// cache_write=… total=…`, each field the first finite number among its spellings,
    /// and only the fields present.
    static func usageLine(_ usage: WireJSON?) -> String? {
        guard let usage, case .object = usage else { return nil }
        let fields: [(label: String, keys: [String])] = [
            ("input", ["inputTokens", "input_tokens"]),
            ("output", ["outputTokens", "output_tokens"]),
            ("cache_read", ["cachedReadTokens", "cacheReadInputTokens", "cache_read_input_tokens"]),
            ("cache_write", ["cachedWriteTokens", "cacheCreationInputTokens", "cache_creation_input_tokens"]),
            ("total", ["totalTokens", "total_tokens"])
        ]
        let parts = fields.compactMap { field in
            firstFiniteNumber(in: usage, field.keys).map { "\(field.label)=\(number($0))" }
        }
        return parts.isEmpty ? nil : "[acpx] tokens: " + parts.joined(separator: " ")
    }

    /// acpx's `formatCostLine`: a number, a non-blank string, or `{amount|value|total,
    /// currency}`.
    static func costLine(_ cost: WireJSON?) -> String? {
        switch cost {
        case .number(let value)? where value.isFinite:
            return "[acpx] cost: \(number(value))"
        case .string?:
            guard let text = cost?.stringValue?.javaScriptTrimmed, !text.isEmpty else { return nil }
            return "[acpx] cost: \(text)"
        case .object?:
            guard let cost, let amount = firstFiniteNumber(in: cost, ["amount", "value", "total"]) else { return nil }
            let currency = cost["currency"]?.stringValue?.javaScriptTrimmed ?? ""
            return "[acpx] cost: \(number(amount))" + (currency.isEmpty ? "" : " \(currency)")
        default:
            return nil
        }
    }

    /// acpx's `readFirstFiniteNumber`.
    private static func firstFiniteNumber(in object: WireJSON, _ keys: [String]) -> Double? {
        for key in keys {
            if case .number(let value)? = object[key], value.isFinite { return value }
        }
        return nil
    }

    /// acpx's `formatMetadataNumber`: an integer as it is, anything else rounded to eight
    /// places — `String(Number(value.toFixed(8)))`.
    static func number(_ value: Double) -> String {
        if value == value.rounded() { return WireJSON.javaScriptString(for: value) }
        return WireJSON.javaScriptString(for: toFixed8(value))
    }

    /// `Number(value.toFixed(8))`: the exact value rounded half up — away from zero —
    /// at the eighth decimal place, then read back. (`toFixed` leaves 1e21 and above as
    /// they are.)
    private static func toFixed8(_ value: Double) -> Double {
        guard abs(value) < 1e21 else { return value }
        // Wide enough to spell out every double whose eighth decimal can be nonzero.
        let exact = String(format: "%.100f", abs(value))
        let parts = exact.split(separator: ".", maxSplits: 1)
        let fraction = Array(parts.count > 1 ? parts[1] : "")
        var digits = Array(parts[0]) + Array(fraction.prefix(8))
        if fraction.count > 8, let ninth = fraction[8].wholeNumberValue, ninth >= 5 {
            var index = digits.count - 1
            while index >= 0, digits[index] == "9" {
                digits[index] = "0"
                index -= 1
            }
            if index >= 0, let digit = digits[index].wholeNumberValue {
                digits[index] = Character(String(digit + 1))
            } else {
                digits.insert("1", at: 0)
            }
        }
        let point = digits.count - 8
        let rounded = Double(String(digits[..<point]) + "." + String(digits[point...])) ?? 0
        return value < 0 ? -rounded : rounded
    }
}
