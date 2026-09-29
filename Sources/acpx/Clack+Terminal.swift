import Foundation

/// A key as Node's readline reads it (`emitKeypressEvents`), for the prompts of skillflag's
/// install wizard (@clack/core 1.5.1).
struct ClackKey {
    /// What was typed, for a key that is not an escape sequence (readline's first argument).
    var text: String?
    /// readline's name for it — `return`, `space`, `up`, `escape`, a letter — if it has one.
    var name: String?
    /// Every byte of it.
    var sequence: String
}

/// The terminal the wizard's prompts run on: their input and output, as clack takes `input` and
/// `output` streams — the process's standard input and output, or `/dev/tty` opened for a piped
/// standard input.
final class ClackTerminal: @unchecked Sendable {
    let input: Int32
    let output: Int32
    private let owned: Bool
    private var cooked: termios?
    private var buffered: [UInt8] = []

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        (self.input, self.output, owned) = (input, output, false)
    }

    private init(opened input: Int32, _ output: Int32) {
        (self.input, self.output, owned) = (input, output, true)
    }

    /// skillflag's `openPromptTty`: `/dev/tty`, for reading and for writing — `nil` when there is
    /// no controlling terminal to open.
    static func controlling() -> ClackTerminal? {
        let input = open("/dev/tty", O_RDONLY)
        guard input >= 0 else { return nil }
        let output = open("/dev/tty", O_WRONLY)
        guard output >= 0 else {
            Darwin.close(input)
            return nil
        }
        return ClackTerminal(opened: input, output)
    }

    /// Close what ``controlling()`` opened.
    func close() {
        guard owned else { return }
        Darwin.close(input)
        Darwin.close(output)
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                return
            }
            bytes = bytes.dropFirst(written)
        }
    }

    /// The window size of the terminal `descriptor` is, if it is one.
    private static func size(of descriptor: Int32) -> winsize? {
        var size = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return size
    }

    /// `process.stdout.columns`, which clack wraps its frames to: `nil` when standard output is no
    /// terminal, and then nothing wraps.
    var stdoutColumns: Int? {
        Self.size(of: STDOUT_FILENO).map { Int($0.ws_col) }
    }

    /// `getColumns(output)`: 80 when the output is no terminal.
    var columns: Int {
        Self.size(of: output).map { Int($0.ws_col) } ?? 80
    }

    /// `getRows(output)`: 20 when the output is no terminal.
    var rows: Int {
        Self.size(of: output).map { Int($0.ws_row) } ?? 20
    }

    /// Node's `setRawMode`, as libuv sets the terminal raw: no echo, no line editing, no signals
    /// from keys, and output still turning `\n` into `\r\n`.
    func setRawMode(_ raw: Bool) {
        guard isatty(input) != 0 else { return }
        if raw {
            var mode = termios()
            guard tcgetattr(input, &mode) == 0 else { return }
            if cooked == nil { cooked = mode }
            mode.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
            mode.c_oflag |= tcflag_t(ONLCR)
            mode.c_cflag |= tcflag_t(CS8)
            mode.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
            withUnsafeMutableBytes(of: &mode.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            tcsetattr(input, TCSADRAIN, &mode)
        } else if var mode = cooked {
            tcsetattr(input, TCSADRAIN, &mode)
            cooked = nil
        }
    }

    /// The next key — readline's `emitKeys`: a character, or an escape and what follows it, a lone
    /// escape taken as the escape key once 50 ms pass with nothing after it (`escapeCodeTimeout`);
    /// `nil` once the input ends.
    func readKey() -> ClackKey? {
        guard var character = nextCharacter() else { return nil }
        var sequence = character
        var escaped = false
        if character == "\u{1B}" {
            escaped = true
            character = nextCharacter(within: 50) ?? ""
            sequence += character
            if character == "\u{1B}" {
                character = nextCharacter(within: 50) ?? ""
                sequence += character
            }
        }
        let name: String?
        if escaped, character == "O" || character == "[" {
            guard let code = escapeCode(after: character, sequence: &sequence) else { return nil }
            name = Self.arrow(code)
        } else {
            name = Self.name(of: character, escaped: escaped)
        }
        return ClackKey(text: escaped ? nil : sequence, name: name, sequence: sequence)
    }

    /// readline's name for a character, after an escape or not.
    private static func name(of character: String, escaped: Bool) -> String? {
        switch character {
        case "\r": return "return"
        case "\n": return "enter"
        case "\t": return "tab"
        case "\u{8}", "\u{7F}": return "backspace"
        case "\u{1B}": return "escape"
        case " ": return "space"
        default: break
        }
        if !escaped, let unit = character.utf16.first, unit <= 0x1A {
            // Control and a letter: the letter.
            return String(UnicodeScalar(UInt8(unit) + 0x60))
        }
        if character.count == 1, let first = character.first, first.isASCII, first.isLetter || first.isNumber {
            return character.lowercased()
        }
        // An escape and nothing after it within the timeout.
        return escaped && character.isEmpty ? "escape" : nil
    }

    /// The code readline makes of `ESC O …` or `ESC [ …`: `first` and what it reads after it, as
    /// many characters as it reads, added to `sequence` — `nil` once the input ends.
    private func escapeCode(after first: String, sequence: inout String) -> String? {
        func next() -> String? {
            let character = nextCharacter()
            sequence += character ?? ""
            return character
        }
        func isDigit(_ character: String) -> Bool { character.count == 1 && character.first?.isASCII == true
            && character.first?.isNumber == true }
        guard var character = next() else { return nil }
        if first == "O" {
            // A modifier, then the letter.
            if isDigit(character) {
                guard let letter = next() else { return nil }
                character = letter
            }
            return first + character
        }
        var code = first
        if character == "[" {
            code += character
            guard let after = next() else { return nil }
            character = after
        }
        // Up to three digits, then a modifier after a semicolon.
        var command = character
        var digits = 0
        while digits < 3, isDigit(character) {
            guard let after = next() else { return nil }
            character = after
            command += character
            digits += 1
        }
        if character == ";" {
            guard let after = next() else { return nil }
            command += after
            if isDigit(after) {
                guard let last = next() else { return nil }
                command += last
            }
        }
        return code + Self.command(Array(command))
    }

    /// What readline takes of the characters after `ESC [` for the code: the number and final
    /// character of `12;5~`, the letter of `1;5A` — or all of them.
    private static func command(_ characters: [Character]) -> String {
        let isDigit = { (character: Character) in character.isASCII && character.isNumber }
        guard let last = characters.last else { return "" }
        let body = Array(characters.dropLast())
        if characters.count == 4, body.allSatisfy(isDigit), last == "~" { return String(characters) }
        if "~^$".contains(last) {
            let parts = body.split(separator: ";", omittingEmptySubsequences: false)
            if (1...2).contains(parts[0].count), parts[0].allSatisfy(isDigit),
               parts.count == 1 || parts.count == 2 && parts[1].count == 1 && parts[1].allSatisfy(isDigit) {
                return String(parts[0]) + String(last)
            }
        }
        if last.isASCII, last.isLetter,
           body.isEmpty || body.count == 1 && isDigit(body[0])
            || body.count == 3 && isDigit(body[0]) && body[1] == ";" && isDigit(body[2]) {
            return String(last)
        }
        return String(characters)
    }

    /// The arrow an escape code names — the only keys named by one that a prompt reacts to.
    private static func arrow(_ code: String) -> String? {
        guard code.count == 2, let letter = code.last else { return nil }
        return ["a": "up", "b": "down", "c": "right", "d": "left"][letter.lowercased()]
    }

    /// The next character of input as Node decodes UTF-8 — a byte that starts no character, or a
    /// character cut short, read as U+FFFD — waiting for it, or for its first byte `within`
    /// milliseconds; `nil` when none comes.
    private func nextCharacter(within milliseconds: Int32? = nil) -> String? {
        guard let lead = nextByte(within: milliseconds) else { return nil }
        let (count, second): (Int, ClosedRange<UInt8>) = switch lead {
        case 0x00...0x7F: (1, 0x80...0xBF)
        case 0xC2...0xDF: (2, 0x80...0xBF)
        case 0xE0: (3, 0xA0...0xBF)
        case 0xED: (3, 0x80...0x9F)
        case 0xE1...0xEF: (3, 0x80...0xBF)
        case 0xF0: (4, 0x90...0xBF)
        case 0xF4: (4, 0x80...0x8F)
        case 0xF1...0xF3: (4, 0x80...0xBF)
        default: (0, 0x80...0xBF)
        }
        guard count > 0 else { return "\u{FFFD}" }
        var bytes = [lead]
        while bytes.count < count {
            guard let byte = nextByte() else { return nil }
            guard (bytes.count == 1 ? second : 0x80...0xBF).contains(byte) else {
                // Read again, as what follows the character cut short.
                buffered.insert(byte, at: 0)
                return "\u{FFFD}"
            }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The next byte of input, waiting for it — or, `within` milliseconds, not longer.
    private func nextByte(within milliseconds: Int32? = nil) -> UInt8? {
        if buffered.isEmpty {
            if let milliseconds {
                var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, milliseconds) > 0 else { return nil }
            }
            var chunk = [UInt8](repeating: 0, count: 256)
            var count: Int
            repeat {
                count = chunk.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            } while count < 0 && errno == EINTR
            guard count > 0 else { return nil }
            buffered = Array(chunk[..<count])
        }
        return buffered.removeFirst()
    }
}
