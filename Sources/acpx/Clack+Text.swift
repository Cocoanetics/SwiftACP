import Foundation

// The text side of the prompts skillflag's install wizard draws with @clack/prompts 1.8.1:
// Node's `util.styleText`, fast-string-width 3.0.2 (fast-string-truncated-width 3.0.3) and
// fast-wrap-ansi 0.2.2, each as that package computes it — the wizard's frames are theirs, byte
// for byte (#294).
enum ClackText {
    /// Whether `styleText` colors: Node's `shouldColorize(process.stdout)` — standard output a
    /// terminal of more than two colors, `FORCE_COLOR` aside — unless a test says (``colorsGiven``).
    static var colors: Bool { colorsGiven ?? processColors }

    /// For a test, whether to color whatever standard output is.
    @TaskLocal static var colorsGiven: Bool?

    private static let processColors: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if let force = environment["FORCE_COLOR"] {
            return force != "0" && force != "false"
        }
        guard isatty(STDOUT_FILENO) != 0 else { return false }
        if environment["NO_COLOR"] != nil || environment["NODE_DISABLE_COLORS"] != nil { return false }
        return environment["TERM"] != "dumb"
    }()

    /// `inspect.colors`: each style's opening and closing SGR codes.
    private static let codes: [String: (open: Int, close: Int)] = [
        "reset": (0, 0), "dim": (2, 22), "inverse": (7, 27), "hidden": (8, 28), "strikethrough": (9, 29),
        "red": (31, 39), "green": (32, 39), "yellow": (33, 39), "blue": (34, 39), "magenta": (35, 39),
        "cyan": (36, 39), "gray": (90, 39), "bgWhite": (47, 49)
    ]

    /// `util.styleText(formats, text)`: the text between each style's opening codes, in order, and
    /// their closing codes, in reverse — no styling where standard output takes no colors.
    static func style(_ formats: String..., text: String) -> String {
        guard colors else { return text }
        var (open, close) = ("", "")
        for format in formats {
            guard let code = codes[format] else { continue }
            open += "\u{1B}[\(code.open)m"
            close = "\u{1B}[\(code.close)m" + close
        }
        return open + text + close
    }

    // MARK: - Width

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants: one that does not compile is a bug.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let ansi = regex(
        #"[\x{1B}\x{9B}][\[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]"#
            + #"|\x{1B}\]8;[^;]*;.*?(?:\x{07}|\x{1B}\\)"#)
    private static let control = regex(#"[\x{00}-\x{08}\x{0A}-\x{1F}\x{7F}-\x{9F}]{1,1000}"#)
    private static let cjkt = regex(
        #"(?:(?![\x{FF61}-\x{FF9F}\x{FF00}-\x{FFEF}])[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}"#
            + #"\p{Script=Hangul}\p{Script=Tangut}]){1,1000}"#)
    private static let tab = regex(#"\t{1,1000}"#)
    private static let emoji = regex(
        #"[\x{1F1E6}-\x{1F1FF}]{2}|\x{1F3F4}[\x{E0061}-\x{E007A}]{2}[\x{E0030}-\x{E0039}\x{E0061}-\x{E007A}]{1,3}"#
            + #"\x{E007F}|(?:\p{Emoji}\x{FE0F}\x{20E3}?|\p{Emoji_Modifier_Base}\p{Emoji_Modifier}?|"#
            + #"\p{Emoji_Presentation})(?:\x{200D}(?:\p{Emoji_Modifier_Base}\p{Emoji_Modifier}?|"#
            + #"\p{Emoji_Presentation}|\p{Emoji}\x{FE0F}\x{20E3}?))*"#)
    private static let latin = regex(#"(?:[\x{20}-\x{7E}\x{A0}-\x{FF}](?!\x{FE0F})){1,1000}"#)
    private static let marks = regex(#"\p{M}+"#)

    /// fast-string-width: how many columns `text` takes — escape sequences and control characters
    /// none, a tab eight, an emoji or a wide character two, anything else one.
    static func width(_ text: String) -> Int {
        let string = text as NSString
        let length = string.length
        let blocks: [(NSRegularExpression, Int)] = [
            (latin, 1), (ansi, 0), (control, 0), (tab, 8), (emoji, 2), (cjkt, 2)
        ]
        var (index, indexPrevious, width) = (0, 0, 0)
        var unmatched: NSRange?
        func measureUnmatched(_ range: NSRange) {
            let text = marks.stringByReplacingMatches(
                in: string.substring(with: range), range: NSRange(location: 0, length: range.length), withTemplate: "")
            for scalar in text.unicodeScalars {
                width += isFullWidth(scalar.value) || isWide(scalar.value) ? 2 : 1
            }
        }
        outer: while true {
            if let range = unmatched, range.length > 0 {
                measureUnmatched(range)
                unmatched = nil
            } else if index >= length, index > indexPrevious {
                measureUnmatched(NSRange(location: indexPrevious, length: index - indexPrevious))
            }
            if index >= length { break }
            for (block, blockWidth) in blocks {
                guard let match = block.firstMatch(
                    in: text, options: .anchored, range: NSRange(location: index, length: length - index)),
                    match.range.length > 0 else { continue }
                let end = match.range.location + match.range.length
                let count = block === cjkt ? codePoints(string.substring(with: match.range))
                    : block === emoji ? 1 : end - index
                width += count * blockWidth
                unmatched = NSRange(location: indexPrevious, length: index - indexPrevious)
                index = end
                indexPrevious = end
                continue outer
            }
            index += 1
        }
        return width
    }

    private static func codePoints(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    private static func isFullWidth(_ value: UInt32) -> Bool {
        value == 0x3000 || (0xFF01...0xFF60).contains(value) || (0xFFE0...0xFFE6).contains(value)
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x231B...0x231B, 0x2329...0x2329, 0x2FF0...0x2FFF, 0x3001...0x303E, 0x3099...0x30FF, 0x3105...0x312F,
        0x3131...0x318E, 0x3190...0x31E3, 0x31EF...0x321E, 0x3220...0x3247, 0x3250...0x4DBF, 0xFE10...0xFE19,
        0xFE30...0xFE52, 0xFE54...0xFE66, 0xFE68...0xFE6B, 0x1F200...0x1F202, 0x1F210...0x1F23B,
        0x1F240...0x1F248, 0x20000...0x2FFFD, 0x30000...0x3FFFD
    ]

    private static func isWide(_ value: UInt32) -> Bool {
        wideRanges.contains { $0.contains(value) }
    }
}

// MARK: - Wrapping

extension ClackText {
    /// fast-wrap-ansi's `wrapAnsi(text, columns, { hard: true, trim: false })`: each line of the
    /// text, normalized to NFC, wrapped at `columns` between its words — a word longer than a line
    /// broken where it reaches the edge — and an SGR style open at a break closed before it and
    /// opened again after.
    static func wrap(_ text: String, columns: Int) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { wrapLine($0, columns: columns) }
            .joined(separator: "\n")
    }

    /// `exec` of one line, with `hard: true` and `trim: false`.
    private static func wrapLine(_ line: String, columns: Int) -> String {
        var rows = [""]
        var rowLength = 0
        for (index, word) in line.components(separatedBy: " ").enumerated() {
            if index != 0 {
                if rowLength >= columns {
                    rows.append("")
                    rowLength = 0
                }
                rows[rows.count - 1] += " "
                rowLength += 1
            }
            let wordLength = width(word)
            if wordLength > columns {
                // In JavaScript's numbers: no room at all (`columns` 0 or less) divides to infinity
                // or NaN, which compare false, and the word goes a character a row.
                let remaining = Double(columns - rowLength)
                let breaksHere = 1 + ((Double(wordLength) - remaining - 1) / Double(columns)).rounded(.down)
                let breaksNext = (Double(wordLength - 1) / Double(columns)).rounded(.down)
                if breaksNext < breaksHere { rows.append("") }
                wrapWord(&rows, word, columns: columns)
                rowLength = width(rows.last ?? "")
                continue
            }
            if rowLength + wordLength > columns, rowLength > 0, wordLength > 0 {
                rows.append("")
                rowLength = 0
            }
            rows[rows.count - 1] += word
            rowLength += wordLength
        }
        return restyled(rows.joined(separator: "\n"))
    }

    /// `wrapWord`: `word` added to the rows a character at a time, a row begun where one is full.
    private static func wrapWord(_ rows: inout [String], _ word: String, columns: Int) {
        let characters = Array(word.unicodeScalars)
        var insideEscape = false
        var insideLink = false
        var visible = width(rows.last ?? "")
        var offset = 0
        for (index, scalar) in characters.enumerated() {
            let character = String(scalar)
            let characterLength = width(character)
            if visible + characterLength <= columns {
                rows[rows.count - 1] += character
            } else {
                rows.append(character)
                visible = 0
            }
            if scalar == "\u{1B}" || scalar == "\u{9B}" {
                insideEscape = true
                insideLink = (word as NSString).substring(from: min(offset + 1, (word as NSString).length))
                    .hasPrefix("]8;;")
            }
            if insideEscape {
                if insideLink {
                    if scalar == "\u{07}" { (insideEscape, insideLink) = (false, false) }
                } else if scalar == "m" {
                    insideEscape = false
                }
            } else {
                visible += characterLength
                if visible == columns, index + 1 < characters.count {
                    rows.append("")
                    visible = 0
                }
            }
            offset += character.utf16.count
        }
        if visible == 0, let last = rows.last, !last.isEmpty, rows.count > 1 {
            rows.removeLast()
            rows[rows.count - 1] += last
        }
    }

    private static let groupPattern = regex(#"(?:\[(?<code>\d+)m|\]8;;(?<uri>.*)\x{07})"#)

    /// The pass that closes the SGR style open at each line break and opens it again after, and
    /// likewise for a hyperlink.
    private static func restyled(_ text: String) -> String {
        let units = Array(text.utf16)
        var result: [UInt16] = []
        var escapeCode: Int?
        var escapeURL: String?
        var index = 0
        var inSurrogate = false
        let string = text as NSString
        while index < units.count {
            let unit = units[index]
            result.append(unit)
            if !inSurrogate, (0xD800...0xDBFF).contains(unit) {
                inSurrogate = true
                index += 1
                continue
            }
            inSurrogate = false
            if unit == 0x1B || unit == 0x9B,
               let match = groupPattern.firstMatch(
                in: text, options: .anchored, range: NSRange(location: index + 1, length: units.count - index - 1)) {
                let code = match.range(withName: "code")
                let uri = match.range(withName: "uri")
                if code.location != NSNotFound, let value = Int(string.substring(with: code)) {
                    escapeCode = value == 39 ? nil : value
                } else if uri.location != NSNotFound {
                    let link = string.substring(with: uri)
                    escapeURL = link.isEmpty ? nil : link
                }
            }
            if index + 1 < units.count, units[index + 1] == 0x0A {
                if escapeURL != nil { result += Array("\u{1B}]8;;\u{07}".utf16) }
                if let code = escapeCode, code != 0, let closing = closingCode(code) {
                    result += Array("\u{1B}[\(closing)m".utf16)
                }
            } else if unit == 0x0A {
                if let code = escapeCode, code != 0, closingCode(code) != nil {
                    result += Array("\u{1B}[\(code)m".utf16)
                }
                if let link = escapeURL { result += Array("\u{1B}]8;;\(link)\u{07}".utf16) }
            }
            index += 1
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// `getClosingCode`.
    private static func closingCode(_ code: Int) -> Int? {
        switch code {
        case 30...37, 90...97: 39
        case 40...47, 100...107: 49
        case 1, 2: 22
        case 3: 23
        case 4: 24
        case 7: 27
        case 8: 28
        case 9: 29
        case 0: 0
        default: nil
        }
    }
}
