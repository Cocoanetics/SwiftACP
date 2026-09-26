import ACPXCore
import Foundation
import SwiftACP

/// acpx's shell action rules that need no process (`src/flows/executors/shell.ts` and
/// `shell-output.ts`, v0.19.3): how a command is shown, what a failure says, and the
/// timeout and capture limit a command runs under.
enum FlowShell {
    /// acpx's `renderShellCommand`: the command, then each argument as `JSON.stringify`
    /// writes it.
    static func renderCommand(_ command: String, _ args: [String]) -> String {
        let rendered = args.map { WireJSON.text($0).stringified }.joined(separator: " ")
        return rendered.isEmpty ? command : "\(command) \(rendered)"
    }

    /// acpx's `formatShellActionSummary`: the step's status while its command runs.
    static func summary(_ command: String, _ args: [String]) -> String {
        "shell: " + renderCommand(command, args)
    }

    /// acpx's `resolveShellActionTimeoutMs`: a positive number of milliseconds, else no
    /// deadline — `0`, a negative number and `NaN` alike.
    static func resolveTimeoutMs(_ timeoutMs: Double?) -> Double? {
        guard let timeoutMs, timeoutMs > 0 else { return nil }
        return timeoutMs
    }

    /// acpx's `createShellFailureError`: the command, how it ended, and its stderr.
    static func failureMessage(
        command: String, args: [String], exitCode: Int?, signal: String?, stderr: String
    ) -> String {
        let status = signal.map { "signal \($0)" } ?? "exit \(exitCode.map(String.init) ?? "null")"
        let details = stderr.isEmpty ? "" : "\n" + stderr.javaScriptTrimmed
        return "Shell action failed (\(renderCommand(command, args))): \(status)\(details)"
    }

    /// acpx's `validateShellActionMaxBufferBytes`: none, or a non-negative safe integer.
    static func validateMaxBufferBytes(_ value: Double?) throws {
        guard let value else { return }
        guard value >= 0, value <= 9_007_199_254_740_991, value.rounded(.towardZero) == value else {
            throw FlowShellError("Shell action maxBufferBytes must be a non-negative safe integer")
        }
    }
}

/// A shell action's failure, in acpx's words.
struct FlowShellError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// acpx's `createShellOutputCapture`, over what Node's `setEncoding("utf8")` hands it:
/// each stream decoded as it comes (``UTF8StreamDecoder``), counted in UTF-8 bytes of
/// what was decoded, and kept while the count is within `maxBufferBytes` — past it, the
/// stream fails the command and keeps nothing more.
struct FlowShellCapture {
    enum Stream: String {
        case stdout
        case stderr
    }

    private(set) var stdout = ""
    private(set) var stderr = ""
    private var bytes: [Stream: Int] = [:]
    private var decoders: [Stream: UTF8StreamDecoder] = [:]
    private let maxBufferBytes: Int?

    init(maxBufferBytes: Double?) {
        self.maxBufferBytes = maxBufferBytes.map { Int($0) }
    }

    /// Take in `chunk` of `stream`: the error it went past the limit with, if it did.
    mutating func append(_ stream: Stream, _ chunk: [UInt8]) -> FlowShellError? {
        let text = decoders[stream, default: UTF8StreamDecoder()].decode(chunk)
        return appendText(stream, text)
    }

    /// The characters `stream` still held half of, at its end — `U+FFFD` each, as Node's
    /// decoder ends.
    mutating func end(_ stream: Stream) -> FlowShellError? {
        let text = decoders[stream, default: UTF8StreamDecoder()].end()
        return text.isEmpty ? nil : appendText(stream, text)
    }

    private mutating func appendText(_ stream: Stream, _ text: String) -> FlowShellError? {
        guard !text.isEmpty else { return nil }
        if let maxBufferBytes {
            let total = bytes[stream, default: 0] + text.utf8.count
            bytes[stream] = total
            if total > maxBufferBytes {
                return FlowShellError(
                    "Shell action exceeded maxBuffer (\(maxBufferBytes) bytes) on \(stream.rawValue)")
            }
        }
        switch stream {
        case .stdout: stdout += text
        case .stderr: stderr += text
        }
        return nil
    }
}

/// Node's `StringDecoder` for UTF-8: the characters a chunk completes, a sequence it
/// leaves unfinished held for the next — so a character split across chunks is decoded
/// whole, and counted once it is — and each ill-formed sequence `U+FFFD`.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func decode(_ chunk: [UInt8]) -> String {
        let bytes = pending + chunk
        let complete = bytes.count - Self.unfinishedTail(bytes)
        pending = Array(bytes[complete...])
        return String(decoding: bytes[..<complete], as: UTF8.self)
    }

    /// What is left when the stream ends: Node's `utf8End`, one `U+FFFD` for a character
    /// left unfinished, however much of it came.
    mutating func end() -> String {
        defer { pending = [] }
        return pending.isEmpty ? "" : "\u{FFFD}"
    }

    /// Node's `utf8CheckIncomplete`: how many bytes at the end begin a character the
    /// chunk does not finish, looking back at most three.
    static func unfinishedTail(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            switch leadLength(byte) {
            case .continuation: continue
            case .invalid: return 0
            case .lead(let length): return length > back ? back : 0
            }
        }
        return 0
    }

    private enum Kind {
        case lead(Int)
        case continuation
        case invalid
    }

    /// Node's `utf8CheckByte`.
    private static func leadLength(_ byte: UInt8) -> Kind {
        if byte <= 0x7F { return .lead(1) }
        if byte >> 5 == 0b110 { return .lead(2) }
        if byte >> 4 == 0b1110 { return .lead(3) }
        if byte >> 3 == 0b11110 { return .lead(4) }
        return byte >> 6 == 0b10 ? .continuation : .invalid
    }
}
