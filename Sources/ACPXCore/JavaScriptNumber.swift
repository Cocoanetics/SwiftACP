import Foundation

/// JavaScript's numeric conversions, where acpx's parsing depends on them: a command
/// line value goes through `Number(value)`, so ` 5`, `0x10` and `1e3` are numbers and
/// an empty string is zero.
public enum JavaScriptNumber {
    /// `Number(string)`: the text without JavaScript's surrounding whitespace, as a
    /// decimal literal (with an optional sign, or `Infinity`), or an unsigned `0x`, `0o`
    /// or `0b` integer. Empty is 0; anything else is NaN.
    public static func parse(_ string: String) -> Double {
        let text = string.javaScriptTrimmed
        guard !text.isEmpty else { return 0 }
        let scalars = Array(text.unicodeScalars)
        if scalars.count > 2, scalars[0] == "0", let radix = radix(scalars[1]) {
            var value = 0.0
            for scalar in scalars.dropFirst(2) {
                guard let digit = digit(scalar), digit < radix else { return .nan }
                value = value * Double(radix) + Double(digit)
            }
            return value
        }
        var body = scalars[...]
        var sign = 1.0
        if let first = body.first, first == "+" || first == "-" {
            if first == "-" { sign = -1 }
            body = body.dropFirst()
        }
        if String(String.UnicodeScalarView(body)) == "Infinity" { return sign * .infinity }
        guard isDecimalLiteral(body) else { return .nan }
        return Double(text) ?? .nan
    }

    /// `Number.isInteger`.
    public static func isInteger(_ value: Double) -> Bool {
        value.isFinite && value.rounded(.towardZero) == value
    }

    /// The largest delay a JavaScript timer takes (`MAX_TIMER_DELAY_MS`).
    public static let maxTimerDelayMs = 2_147_483_647

    /// acpx's `toTimerMilliseconds`: zero stays zero where allowed; anything else is at
    /// least 1 ms, rounded half up as `Math.round` rounds, and within the timer maximum.
    public static func timerMilliseconds(_ seconds: Double, allowZero: Bool) -> Int? {
        if allowZero && seconds == 0 { return 0 }
        let milliseconds = max(1, (seconds * 1000 + 0.5).rounded(.down))
        return milliseconds <= Double(maxTimerDelayMs) ? Int(milliseconds) : nil
    }

    // MARK: -

    private static func radix(_ marker: Unicode.Scalar) -> Int? {
        switch marker {
        case "x", "X": return 16
        case "o", "O": return 8
        case "b", "B": return 2
        default: return nil
        }
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value - 48)
        case "a"..."f": return Int(scalar.value - 87)
        case "A"..."F": return Int(scalar.value - 55)
        default: return nil
        }
    }

    /// `StrUnsignedDecimalLiteral`: digits with an optional fraction (at least one digit
    /// in all), then an optional exponent.
    private static func isDecimalLiteral(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool {
        var rest = scalars
        func digits() -> Int {
            var count = 0
            while let next = rest.first, ("0"..."9").contains(next) {
                rest = rest.dropFirst()
                count += 1
            }
            return count
        }
        var mantissa = digits()
        if rest.first == "." {
            rest = rest.dropFirst()
            mantissa += digits()
        }
        guard mantissa > 0 else { return false }
        if let marker = rest.first, marker == "e" || marker == "E" {
            rest = rest.dropFirst()
            if let sign = rest.first, sign == "+" || sign == "-" { rest = rest.dropFirst() }
            guard digits() > 0 else { return false }
        }
        return rest.isEmpty
    }
}
