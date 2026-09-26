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

    /// acpx's `resolveShellActionTimeoutMs`: the value as given when JavaScript's `> 0`
    /// holds for it — a positive number, or a string, boolean or list that converts to one
    /// — else no deadline: `0`, a negative number, `NaN`, and what converts to none of them.
    static func resolveTimeout(_ timeoutMs: WireJSON?) -> WireJSON? {
        guard let timeoutMs, javaScriptNumber(timeoutMs) > 0 else { return nil }
        return timeoutMs
    }

    /// The delay Node's `setTimeout` runs `timeout` after: its number, at least 1 ms. Node
    /// runs a delay above 2,147,483,647 ms after 1 ms as well, which times the command out
    /// at once (openclaw/acpx#812); here such a delay is taken as given.
    static func timerDelayMs(_ timeout: WireJSON) -> Double {
        let delay = javaScriptNumber(timeout)
        return delay >= 1 ? delay : 1
    }

    /// JavaScript's `Number(value)` for a JSON value: a string as `Number` reads it, a
    /// boolean as 1 or 0, a list as the text it joins to, `null` as 0, an object as NaN.
    static func javaScriptNumber(_ value: WireJSON) -> Double {
        switch value {
        case .number(let number): return number
        case .string(let units): return JavaScriptNumber.parse(String(decoding: units, as: UTF16.self))
        case .bool(let flag): return flag ? 1 : 0
        case .null: return 0
        case .array: return JavaScriptNumber.parse(SessionArchive.javaScriptString(value))
        case .object: return .nan
        }
    }

    /// acpx's `new TimeoutError(timeoutMs ?? spec.timeoutMs ?? 0)` for a command past its
    /// deadline: the message shows the value as JavaScript's `${…}` writes it.
    static func timeoutError(_ spec: FlowShellExecution) -> FlowTimeoutError {
        var given = spec.timeoutMs
        if given == .null { given = nil }
        let timeout = resolveTimeout(spec.timeoutMs) ?? given ?? .number(0)
        let shown: String? = if case .number = timeout { nil } else { SessionArchive.javaScriptString(timeout) }
        return FlowTimeoutError(timeoutMs: javaScriptNumber(timeout), shown: shown)
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

/// A shell action's failure, in acpx's words — or in Node's, for an argument it refuses,
/// with the code that makes the error a `TypeError` (`ERR_INVALID_ARG_TYPE`).
struct FlowShellError: Error, LocalizedError {
    let message: String
    let code: String?
    init(_ message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
    var errorDescription: String? { message }

    /// Node's `ERR_INVALID_ARG_TYPE`.
    static func invalidArgType(_ message: String) -> FlowShellError {
        FlowShellError(message, code: "ERR_INVALID_ARG_TYPE")
    }
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

/// What a shell action's `exec`, or `ctx.runShell`, asked to run: acpx's
/// `ShellActionExecution` (`runShell` takes no `allowNonZeroExit`), as the JSON the host
/// sent of it. It is read as leniently as acpx reads it — a spec of the wrong shape still
/// shows in the step's status and trace — and fails, when started, as Node's `spawn` fails.
struct FlowShellExecution: Sendable {
    /// The members as the flow gave them.
    let json: WireJSON

    init(json: WireJSON) {
        self.json = json
    }

    /// `command`, when it is a string.
    var command: String? { json["command"]?.stringValue }

    /// acpx's `spec.args ?? []`, each as JavaScript's `String` makes it.
    var args: [String] {
        guard case .array(let items)? = json["args"] else { return [] }
        return items.map { SessionArchive.javaScriptString($0) }
    }

    var cwd: WireJSON? { json["cwd"] }
    var stdin: WireJSON? { json["stdin"] }
    var shell: WireJSON? { json["shell"] }
    var allowNonZeroExit: Bool { json["allowNonZeroExit"] == .bool(true) }

    /// `timeoutMs` as given, which acpx takes as JavaScript compares it
    /// (``FlowShell/resolveTimeout(_:)``).
    var timeoutMs: WireJSON? { json["timeoutMs"] }

    /// `maxBufferBytes`: a number as it is; anything else, which acpx's check refuses, NaN.
    var maxBufferBytes: Double? {
        switch json["maxBufferBytes"] {
        case nil, .null?: return nil
        case .number(let value)?: return value
        default: return .nan
        }
    }

    /// acpx's `{ ...process.env, ...spec.env }`, each value as JavaScript's template string
    /// makes it (`${value}`).
    func environment(inheriting parent: [String: String]) -> [String: String] {
        var environment = parent
        for member in json["env"]?.objectMembers ?? [] {
            environment[String(decoding: member.key, as: UTF16.self)] = SessionArchive.javaScriptString(member.value)
        }
        return environment
    }

    /// Node's `normalizeSpawnArguments`: the file and arguments `spawn` runs — a shell's
    /// `-c` with the command line joined, for `shell` — or the error it throws.
    func spawnArguments() throws -> (file: String, arguments: [String]) {
        guard let command else {
            throw FlowShellError.invalidArgType(NodeArgumentError.type("file", "of type string", json["command"]))
        }
        guard !command.isEmpty else {
            throw FlowShellError("The argument 'file' cannot be empty. Received ''", code: "ERR_INVALID_ARG_VALUE")
        }
        switch json["args"] {
        case nil, .null?, .array?: break
        case .object?: break
        case let other?: throw FlowShellError.invalidArgType(NodeArgumentError.type("args", "of type object", other))
        }
        switch shell {
        case nil, .null?, .bool(false)?: return (command, args)
        case .bool(true)?: return ("/bin/sh", ["-c", ([command] + args).joined(separator: " ")])
        case .string(let units)?:
            let path = String(decoding: units, as: UTF16.self)
            return path.isEmpty ? (command, args) : (path, ["-c", ([command] + args).joined(separator: " ")])
        case let other?:
            throw FlowShellError.invalidArgType(
                NodeArgumentError.property("options.shell", "one of type boolean or string", other))
        }
    }
}

/// Node's `ERR_INVALID_ARG_TYPE` messages, with `determineSpecificType`'s account of the
/// value received.
enum NodeArgumentError {
    static func type(_ name: String, _ expected: String, _ value: WireJSON?) -> String {
        "The \"\(name)\" argument must be \(expected). Received \(received(value))"
    }

    static func property(_ name: String, _ expected: String, _ value: WireJSON?) -> String {
        "The \"\(name)\" property must be \(expected). Received \(received(value))"
    }

    /// Node's `determineSpecificType`.
    static func received(_ value: WireJSON?) -> String {
        switch value {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool(let flag)?: return "type boolean (\(flag))"
        case .number(let number)?:
            if number == 0, number.sign == .minus { return "type number (-0)" }
            return "type number (\(WireJSON.javaScriptString(for: number)))"
        case .string(let units)?:
            var text = String(decoding: units, as: UTF16.self)
            if units.count > 28 { text = String(decoding: units.prefix(25), as: UTF16.self) + "..." }
            return text.contains("'") ? "type string (\(WireJSON.text(text).stringified))" : "type string ('\(text)')"
        case .array?: return "an instance of Array"
        case .object?: return "an instance of Object"
        }
    }
}
