import Foundation

/// Serialized writes to stdout/stderr so concurrent tasks (streaming output and
/// permission prompts) don't interleave mid-line.
enum Console {
    private static let lock = NSLock()

    /// Output captured instead of written, while bound (``capture``): how a test runs the
    /// whole CLI and compares what it printed.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = ""
        private var stderr = ""
        private var both = ""
        private var stdoutBytes = Data()

        var out: String { lock.withLock { stdout } }
        var err: String { lock.withLock { stderr } }
        /// Both streams as they were written, in order, as `2>&1` shows them.
        var merged: String { lock.withLock { both } }
        /// Every byte written to stdout, text or not.
        var outBytes: Data { lock.withLock { stdoutBytes } }

        fileprivate func write(_ text: String, toStandardError: Bool) {
            write(Data(text.utf8), toStandardError: toStandardError)
        }

        fileprivate func write(_ data: Data, toStandardError: Bool) {
            let text = String(decoding: data, as: UTF8.self)
            lock.withLock {
                if toStandardError { stderr += text } else { stdout += text; stdoutBytes += data }
                both += text
            }
        }
    }

    @TaskLocal static var capture: Capture?

    static func out(_ text: String) {
        if let capture {
            capture.write(text, toStandardError: false)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func err(_ text: String) {
        if let capture {
            capture.write(text, toStandardError: true)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func errLine(_ text: String) { err(text + "\n") }

    /// Bytes to stdout as they are: a tar, say.
    static func outBytes(_ data: Data) {
        if let capture {
            capture.write(data, toStandardError: false)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    /// Bytes to stderr as they are: what another program said there.
    static func errBytes(_ data: Data) {
        if let capture {
            capture.write(data, toStandardError: true)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(data)
    }
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
