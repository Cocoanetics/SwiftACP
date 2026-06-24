import Foundation

/// Serialized writes to stdout/stderr so concurrent tasks (streaming output and
/// permission prompts) don't interleave mid-line.
enum Console {
    private static let lock = NSLock()

    static func out(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func err(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func errLine(_ text: String) { err(text + "\n") }
}

/// ANSI styling for stderr-bound CLI chrome (banners, permission prompts).
/// Suppressed when stderr is not a TTY. The transcript formatter has its own
/// stdout-based color handling.
enum Style {
    static let stderrIsTTY = isatty(fileno(stderr)) != 0

    static func dim(_ text: String) -> String { wrap(text, "2") }
    static func bold(_ text: String) -> String { wrap(text, "1") }
    static func cyan(_ text: String) -> String { wrap(text, "36") }
    static func yellow(_ text: String) -> String { wrap(text, "33") }
    static func green(_ text: String) -> String { wrap(text, "32") }
    static func red(_ text: String) -> String { wrap(text, "31") }

    private static func wrap(_ text: String, _ code: String) -> String {
        guard stderrIsTTY else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }
}
