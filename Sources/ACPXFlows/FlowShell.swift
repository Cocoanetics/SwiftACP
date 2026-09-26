import ACPXCore
import Foundation
import SwiftACP

#if canImport(Darwin)
import Darwin
#endif

/// acpx's shell action rules that need no process (`src/flows/executors/shell.ts` and
/// `shell-output.ts`, v0.19.3): how a command is shown, what a failure says, and the
/// timeout and capture limit a command runs under.
enum FlowShell {
    /// acpx's `renderShellCommand`: the command, then each argument as `JSON.stringify`
    /// writes it — nothing for one it leaves out — or the error it throws for one.
    static func renderCommand(_ command: String, _ args: [WireJSON]) throws -> String {
        let rendered = try args.map { try FlowJS.written($0)?.stringified ?? "" }.joined(separator: " ")
        return rendered.isEmpty ? command : "\(command) \(rendered)"
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
        case .object:
            switch FlowJS.marker(value) {
            case .number(let number)?, .instance(_, _, _, let number)?: return number
            default: return .nan
            }
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

    /// acpx's `createShellFailureError`: the command, how it ended, and its stderr. (Its
    /// arguments were rendered for the step's status already, so they render here.)
    static func failureMessage(
        command: String, args: [WireJSON], exitCode: Int?, signal: String?, stderr: String
    ) -> String {
        let status = signal.map { "signal \($0)" } ?? "exit \(exitCode.map(String.init) ?? "null")"
        let details = stderr.isEmpty ? "" : "\n" + stderr.javaScriptTrimmed
        let rendered = (try? renderCommand(command, args)) ?? command
        return "Shell action failed (\(rendered)): \(status)\(details)"
    }

    /// acpx's `validateShellActionMaxBufferBytes`: none, or a non-negative safe integer.
    static func validateMaxBufferBytes(_ value: Double?) throws {
        guard let value else { return }
        guard value >= 0, value <= 9_007_199_254_740_991, value.rounded(.towardZero) == value else {
            throw FlowShellError("Shell action maxBufferBytes must be a non-negative safe integer")
        }
    }
}

/// A shell action's failure, in acpx's words — or in Node's or JavaScript's, for a value
/// they refuse: a `TypeError`, with Node's code (`ERR_INVALID_ARG_TYPE`) when it is Node's.
struct FlowShellError: Error, LocalizedError {
    let message: String
    let code: String?
    /// The error's name, when it is not `Error`: a `TypeError` for one with a code.
    let name: String?
    init(_ message: String, code: String? = nil, name: String? = nil) {
        self.message = message
        self.code = code
        self.name = name ?? (code == nil ? nil : "TypeError")
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

    /// acpx's `spec.args ?? []` as the flow gave it, what the step's status, trace and
    /// result show: each argument as the host sent it, a value JSON loses marked
    /// (``FlowJS/Marker``).
    var rawArgs: [WireJSON] {
        guard case .array(let items)? = json["args"] else { return [] }
        return items
    }

    /// The arguments the command gets, as Node's `spawn` converts them — `String(arg)`, or
    /// with `shell` as `Array.join` does, `null` and `undefined` empty — as the host made
    /// them, else from the JSON.
    var args: [String] {
        if case .array(let items)? = json[FlowJS.argvKey], items.allSatisfy({ $0.stringValue != nil }) {
            return items.compactMap(\.stringValue)
        }
        return rawArgs.map { arg in
            if isShell, arg == .null || FlowJS.marker(arg) == .undefined { return "" }
            return FlowJS.string(arg)
        }
    }

    /// `text` up to its first NUL, as a C string reads it.
    static func cString(_ text: String) -> String {
        guard let end = text.utf16.firstIndex(of: 0) else { return text }
        return String(text.utf16[..<end]) ?? text
    }

    /// Whether Node's `spawn` runs the command in a shell: `shell` is `true`, or a path.
    var isShell: Bool { Self.runsInShell(shell) }

    static func runsInShell(_ shell: WireJSON?) -> Bool {
        switch shell {
        case .bool(true)?: return true
        case .string(let units)?: return !units.isEmpty
        default: return false
        }
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
        case let other?:
            if case .number(let value)? = FlowJS.marker(other) { return value }
            return .nan
        }
    }

    /// acpx's `spec.env`, each value as JavaScript's template string makes it (`${value}`),
    /// `undefined` left out — as the host converted it.
    var env: [(name: String, value: String)] { Self.variables(json["env"]) }

    /// An `env` object's variables, each value as `${value}`, `undefined` left out.
    static func variables(_ env: WireJSON?) -> [(name: String, value: String)] {
        (env?.objectMembers ?? []).compactMap { member in
            if FlowJS.marker(member.value) == .undefined { return nil }
            return (String(decoding: FlowJS.unescaped(member.key), as: UTF16.self), FlowJS.string(member.value))
        }
    }

    /// acpx's `{ ...process.env, ...spec.env }`, in the order Node lists it: this process's
    /// variables in their order, each the spec sets taking its value in place, then the
    /// spec's new ones in its order.
    func environment(inheriting parent: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var environment = parent
        for (name, value) in env {
            if let index = environment.firstIndex(where: { $0.name == name }) {
                environment[index].value = value
            } else {
                environment.append((name, value))
            }
        }
        return environment
    }

    /// This process's environment in `environ`'s order, which Node's `process.env` lists.
    /// Swift has no name for `environ` itself, so it is looked up as a symbol.
    static var processEnvironment: [(name: String, value: String)] {
        typealias Environ = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, "environ"),
              var entry = address.assumingMemoryBound(to: Environ?.self).pointee else {
            return ProcessInfo.processInfo.environment.map { ($0.key, $0.value) }
        }
        var variables: [(name: String, value: String)] = []
        while let pointer = entry.pointee {
            let text = String(cString: pointer)
            if let equals = text.firstIndex(of: "=") {
                variables.append((String(text[..<equals]), String(text[text.index(after: equals)...])))
            }
            entry += 1
        }
        return variables
    }

    /// Node's `normalizeSpawnArguments`, in its order: the file and arguments `spawn` runs —
    /// a shell's `-c` with the command line joined, for `shell` — or the error it throws,
    /// for a value of the wrong type, a string with a NUL, or one the host could not
    /// convert.
    func spawnArguments(cwd: String) throws -> (file: String, arguments: [String]) {
        let spawn = try spawnPlan(cwd: cwd, inheriting: [])
        return (spawn.file, spawn.arguments)
    }

    /// ``spawnArguments(cwd:)``, and where and how `spawn` starts the command. `args` that
    /// are an object, not a list, are Node's options in place of acpx's own — the command's
    /// `cwd`, `env`, `shell` and `detached` then come from it, with no arguments.
    func spawnPlan(cwd: String, inheriting parent: [(name: String, value: String)]) throws -> FlowShellSpawn {
        guard case .object = json["args"], FlowJS.marker(json["args"] ?? .null) == nil else {
            let (file, arguments) = try spawnFileAndArguments(
                cwd: .text(cwd), shell: shell, args: args, env: env, envError: json[FlowJS.envErrorKey]?.stringValue)
            return FlowShellSpawn(
                file: file, arguments: arguments, cwd: cwd, environment: environment(inheriting: parent),
                newSession: true)
        }
        let options = json["args"]
        var variables: [(name: String, value: String)] = []
        var envError: String?
        if let env = options?["env"], case .object = env {
            switch FlowJS.marker(env) {
            case nil: variables = Self.variables(env)
            case .refused(let message, _)?: envError = message
            default: break
            }
        }
        let (file, arguments) = try spawnFileAndArguments(
            cwd: options?["cwd"], shell: options?["shell"], args: [], env: variables, envError: envError)
        // `options.env || process.env`.
        let environment = FlowJS.truthy(options?["env"]) ? variables : parent
        return FlowShellSpawn(
            file: file, arguments: arguments, cwd: options?["cwd"]?.stringValue, environment: environment,
            newSession: FlowJS.truthy(options?["detached"]))
    }

    private func spawnFileAndArguments(
        cwd: WireJSON?, shell: WireJSON?, args: [String], env: [(name: String, value: String)], envError: String?
    ) throws -> (file: String, arguments: [String]) {
        guard let command else {
            throw FlowShellError.invalidArgType(NodeArgumentError.type("file", "of type string", json["command"]))
        }
        try FlowShellError.checkNullBytes(command, "file")
        guard !command.isEmpty else { throw FlowShellError.invalidArgValue("file", "", reason: "cannot be empty") }
        switch json["args"] {
        case nil, .null?, .array?: break
        case .object? where FlowJS.marker(json["args"] ?? .null) == nil: break
        case let other?: throw FlowShellError.invalidArgType(NodeArgumentError.type("args", "of type object", other))
        }
        for (index, arg) in rawArgs.enumerated() {
            if case .string(let units) = arg {
                try FlowShellError.checkNullBytes(String(decoding: units, as: UTF16.self), "args[\(index)]")
            }
        }
        switch cwd {
        case nil, .null?: break
        case .string(let units)?:
            try FlowShellError.checkNullBytes(
                String(decoding: units, as: UTF16.self), "options.cwd",
                reason: "must be a string, Uint8Array, or URL without null bytes")
        case let other?:
            if case .refused(let message, let code)? = FlowJS.marker(other) {
                throw FlowShellError(message, code: code, name: "TypeError")
            }
            throw FlowShellError.invalidArgType(NodeArgumentError.property(
                "options.cwd", "of type string or an instance of Buffer or URL", other))
        }
        switch shell {
        case nil, .null?, .bool?: break
        case .string(let units)?:
            try FlowShellError.checkNullBytes(String(decoding: units, as: UTF16.self), "options.shell")
        case let other?:
            throw FlowShellError.invalidArgType(
                NodeArgumentError.property("options.shell", "one of type boolean or string", other))
        }
        if let failure = json[FlowJS.argvErrorKey]?.stringValue { throw FlowShellError(failure, name: "TypeError") }
        // Past Node's checks, a NUL can only come of converting a value that was not a string,
        // and the argument ends at it, as a C string does — with `shell`, the whole command.
        var file = command
        var arguments = args.map(Self.cString)
        if Self.runsInShell(shell) {
            file = "/bin/sh"
            if case .string(let units)? = shell { file = String(decoding: units, as: UTF16.self) }
            arguments = ["-c", Self.cString(([command] + args).joined(separator: " "))]
        }
        if let envError { throw FlowShellError(envError, name: "TypeError") }
        for (name, value) in env {
            try FlowShellError.checkNullBytes(name, "options.env['\(name)']")
            try FlowShellError.checkNullBytes(value, "options.env['\(name)']")
        }
        return (file, arguments)
    }
}

/// What Node's `spawn` starts: the file and its arguments, where — `nil` for this process's
/// own directory — with what environment, and whether in a session of its own.
struct FlowShellSpawn {
    let file: String
    let arguments: [String]
    let cwd: String?
    let environment: [(name: String, value: String)]
    let newSession: Bool
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
        if let value, let marker = FlowJS.marker(value) { return FlowJS.received(marker) }
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
