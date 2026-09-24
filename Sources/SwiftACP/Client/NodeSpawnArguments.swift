import Foundation

/// The checks Node's `child_process.spawn` makes before starting anything
/// (`normalizeSpawnArguments`), in its words: what acpx's `terminal/create` answers
/// when one fails. A NUL matters most. C would end the string there, so a command
/// shown to the user as one thing would run as another; Node refuses it outright, and
/// so does this.
enum NodeSpawnArguments {
    /// Throw ``TerminalError/invalidSpawnArgument(_:)`` for the first value Node would
    /// refuse, in its order: the command, each argument, the directory, then each
    /// variable's name and value.
    static func validate(command: String, args: [String], cwd: String, env: [EnvVariable]?) throws {
        try refuseNUL(in: command, "The argument 'file'")
        if command.isEmpty {
            throw TerminalError.invalidSpawnArgument("The argument 'file' cannot be empty. Received ''")
        }
        for (index, argument) in args.enumerated() {
            try refuseNUL(in: argument, "The argument 'args[\(index)]'")
        }
        if cwd.contains("\0") {
            throw TerminalError.invalidSpawnArgument(
                "The property 'options.cwd' must be a string, Uint8Array, or URL without null bytes. "
                    + "Received \(inspected(cwd))")
        }
        for variable in env ?? [] {
            try refuseNUL(in: variable.name, "The property 'options.env['\(variable.name)']'")
            try refuseNUL(in: variable.value, "The property 'options.env['\(variable.name)']'")
        }
    }

    private static func refuseNUL(in value: String, _ subject: String) throws {
        guard value.contains("\0") else { return }
        throw TerminalError.invalidSpawnArgument(
            "\(subject) must be a string without null bytes. Received \(inspected(value))")
    }

    /// Node's `util.inspect` of a string as `ERR_INVALID_ARG_VALUE` quotes it. Longer
    /// than 76 characters, it is split after each newline, each piece quoted on its own
    /// and joined with ` +` and a new line. The whole is cut at 128 characters with an
    /// ellipsis.
    static func inspected(_ value: String) -> String {
        var text: String
        if value.utf16.count > 76 {
            // By scalar: a "\r\n" is one `Character`, but Node splits after its "\n".
            var pieces: [String] = []
            var piece = String.UnicodeScalarView()
            for scalar in value.unicodeScalars {
                piece.append(scalar)
                if scalar == "\n" {
                    pieces.append(String(piece))
                    piece = String.UnicodeScalarView()
                }
            }
            if !piece.isEmpty || pieces.isEmpty { pieces.append(String(piece)) }
            text = pieces.map(quoted).joined(separator: " +\n  ")
        } else {
            text = quoted(value)
        }
        let units = Array(text.utf16)
        guard units.count > 128 else { return text }
        return String(decoding: units.prefix(128), as: UTF16.self) + "..."
    }

    /// One quoted piece: in single quotes unless the text holds one, then double quotes,
    /// then backticks. Controls (C0, DEL and C1) as `\xHH`, but for the short escapes;
    /// the quote in use and the backslash escaped.
    static func quoted(_ value: String) -> String {
        let quote: Unicode.Scalar
        if !value.contains("'") {
            quote = "'"
        } else if !value.contains("\"") {
            quote = "\""
        } else if !value.contains("`") && !value.contains("${") {
            quote = "`"
        } else {
            quote = "'"
        }
        var out = String.UnicodeScalarView([quote])
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: out.append(contentsOf: "\\b".unicodeScalars)
            case 0x09: out.append(contentsOf: "\\t".unicodeScalars)
            case 0x0A: out.append(contentsOf: "\\n".unicodeScalars)
            case 0x0C: out.append(contentsOf: "\\f".unicodeScalars)
            case 0x0D: out.append(contentsOf: "\\r".unicodeScalars)
            case 0x00...0x1F, 0x7F...0x9F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                out.append(contentsOf: ("\\x" + (hex.count < 2 ? "0" + hex : hex)).unicodeScalars)
            case 0x5C: out.append(contentsOf: "\\\\".unicodeScalars)
            case 0x27 where quote == "'": out.append(contentsOf: "\\'".unicodeScalars)
            default: out.append(scalar)
            }
        }
        out.append(quote)
        return String(out)
    }
}
