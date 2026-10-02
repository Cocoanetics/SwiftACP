@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// acpx's shell action rules that need no process (`test/flows-shell.test.ts`, v0.19.3),
/// and the UTF-8 decoding Node's `setEncoding("utf8")` does for its capture.
struct FlowShellTests {
    /// acpx: "renderShellCommand quotes arguments consistently" — each argument as
    /// `JSON.stringify` writes the flow's own value: a number bare, `undefined` as nothing,
    /// and a BigInt, which it refuses, failing.
    @Test func aCommandIsShownWithItsArgumentsQuoted() throws {
        #expect(try FlowShell.renderCommand("echo", [.text("hello"), .text("two words")])
            == #"echo "hello" "two words""#)
        #expect(try FlowShell.renderCommand("ls", []) == "ls")
        #expect(try FlowShell.renderCommand("printf", [.text("a\"b\n")]) == #"printf "a\"b\n""#)
        #expect(try FlowShell.renderCommand("head", [.text("-n"), .number(5), .null]) == #"head "-n" 5 null"#)
        let undefined = WireJSON.object([(FlowJS.markerKey, .text("undefined"))])
        #expect(try FlowShell.renderCommand("echo", [undefined]) == "echo")
        #expect(try FlowShell.renderCommand("echo", [undefined, .text("x")]) == #"echo  "x""#)
        let bigint = WireJSON.object([(FlowJS.markerKey, .text("bigint")), ("text", .text("5"))])
        #expect(throws: FlowShellError.self) { try FlowShell.renderCommand("echo", [bigint]) }
    }

    /// acpx: "formatShellActionSummary prefixes rendered commands" — and `args` that are not
    /// a list fail it, as `args.map` does.
    @Test func theSummaryPrefixesTheCommand() throws {
        let spec = { (args: WireJSON) in
            FlowShellExecution(json: .object([("command", .text("git")), ("args", args)]))
        }
        #expect(try FlowShell.summary(of: spec(.array([.text("status"), .text("--short")])))
            == #"shell: git "status" "--short""#)
        #expect(try FlowShell.summary(of: spec(.null)) == "shell: git")
        let failure = #expect(throws: FlowShellError.self) { try FlowShell.summary(of: spec(.text("status"))) }
        #expect(failure?.message == "args.map is not a function")
    }

    /// The markers for what JSON cannot carry, read as acpx's JavaScript reads the values:
    /// a non-finite number written as `null` and converted by `String`, refused as a
    /// capture limit and as a timeout.
    @Test func whatJSONCannotCarryReadsAsJavaScriptReadsIt() throws {
        let marker = { (kind: String, text: String) in
            WireJSON.object([(FlowJS.markerKey, .text(kind)), ("text", .text(text))])
        }
        let infinity = marker("number", "Infinity")
        #expect(FlowJS.marker(infinity) == .number(.infinity))
        #expect(try FlowJS.written(infinity) == .null)
        #expect(FlowJS.string(marker("number", "-Infinity")) == "-Infinity")
        #expect(FlowJS.string(marker("number", "NaN")) == "NaN")
        #expect(NodeArgumentError.received(marker("number", "NaN")) == "type number (NaN)")
        #expect(throws: FlowTimerLimitError()) { try FlowShell.resolveTimeout(infinity) }
        #expect(throws: FlowTimerLimitError()) { try FlowShell.resolveTimeout(marker("number", "NaN")) }
        let limit = FlowShellExecution(json: .object([("maxBufferBytes", infinity)])).maxBufferBytes
        #expect(limit == .infinity)
        #expect(throws: FlowShellError.self) { try FlowShell.validateMaxBufferBytes(limit) }
    }

    /// Node's `util.inspect` of a string, as its `ERR_INVALID_ARG_VALUE` shows one: the
    /// cases are what Node 22 prints.
    @Test func aStringIsInspectedAsNodeInspectsIt() {
        let cases: [(String, String)] = [
            ("a\u{0}b", #"'a\x00b'"#), ("it's", #""it's""#), (#"say "hi""#, #"'say "hi"'"#),
            (#"both ' and ""#, #"`both ' and "`"#), (#"all ' " and `"#, #"'all \' " and `'"#),
            ("tmpl ' \" ${x}", #"'tmpl \' " ${x}'"#), ("\n\t\r\u{8}\u{C}\u{B}", #"'\n\t\r\b\f\x0B'"#),
            ("\u{7F}\u{85}\u{9F}\u{A0}", "'\\x7F\\x85\\x9F\u{A0}'"), ("é😀", "'é😀'"),
            (#"a\b"#, #"'a\\b'"#), ("", "''")
        ]
        for (text, inspected) in cases {
            #expect(NodeInspect.string(text) == inspected, "\(text.debugDescription)")
        }
        #expect(NodeInspect.string(String(repeating: "line\n", count: 30)).hasPrefix("'line\\n' +\n  'line\\n' +\n"))
    }

    /// Node's `spawn` refuses a string with a NUL, naming it — the file, an argument, the
    /// working directory, the shell, an environment variable — before it starts anything.
    @Test func aNulIsRefusedAsNodeRefusesIt() {
        func refusal(_ members: [(String, WireJSON?)], cwd: String = "/tmp") -> String? {
            do {
                _ = try FlowShellExecution(json: .object(members)).spawnArguments(cwd: cwd)
                return nil
            } catch let error as FlowShellError {
                return error.code == "ERR_INVALID_ARG_VALUE" ? error.message : "wrong code: \(error.message)"
            } catch {
                return "\(error)"
            }
        }
        let echo: (String, WireJSON?) = ("command", .text("/bin/echo"))
        #expect(refusal([("command", .text("/bin/ec\u{0}ho"))])
            == "The argument 'file' must be a string without null bytes. Received '/bin/ec\\x00ho'")
        #expect(refusal([echo, ("args", .array([.text("a"), .text("b\u{0}c")]))])
            == "The argument 'args[1]' must be a string without null bytes. Received 'b\\x00c'")
        #expect(refusal([echo, ("args", .array([.text("it's\u{0}")]))])
            == "The argument 'args[0]' must be a string without null bytes. Received \"it's\\x00\"")
        #expect(refusal([echo], cwd: "/tmp\u{0}x") == "The property 'options.cwd' must be a string, Uint8Array, or URL "
            + "without null bytes. Received '/tmp\\x00x'")
        #expect(refusal([echo, ("shell", .text("/bin/s\u{0}h"))])
            == "The property 'options.shell' must be a string without null bytes. Received '/bin/s\\x00h'")
        #expect(refusal([echo, ("env", .object([("A", .text("x\u{0}y"))]))])
            == "The property 'options.env['A']' must be a string without null bytes. Received 'x\\x00y'")
        #expect(refusal([echo, ("env", .object([("A\u{0}B", .text("x"))]))])
            == "The property 'options.env['A\u{0}B']' must be a string without null bytes. Received 'A\\x00B'")
        let long = String(repeating: "x", count: 130) + "\u{0}"
        #expect(refusal([echo, ("args", .array([.text(long)]))])
            == "The argument 'args[0]' must be a string without null bytes. Received '"
            + String(repeating: "x", count: 127) + "...")
        #expect(refusal([echo, ("args", .array([.text("fine")]))]) == nil)
    }

    /// acpx: "resolveShellActionTimeoutMs treats non-positive as no deadline", and 0.19.4's
    /// `resolveFlowTimeoutMs` (openclaw/acpx#812): a positive number within Node's timer
    /// limit is the deadline; `undefined`, 0 and a negative number are none; anything else —
    /// a number past the limit, `NaN`, an infinity, a string that reads as one, `null`, a
    /// boolean, a list, an object — is refused with acpx's `TypeError`, in its words.
    @Test func onlyAPositiveNumberWithinNodesTimerLimitIsADeadline() throws {
        for none in [nil, .number(0), .number(-1)] as [WireJSON?] {
            #expect(try FlowShell.resolveTimeout(none) == nil, "\(String(describing: none))")
        }
        for (deadline, resolved) in [(.number(50), 50), (.number(0.5), 0.5), (.number(2_147_483_647), 2_147_483_647)]
            as [(WireJSON, Double)] {
            #expect(try FlowShell.resolveTimeout(deadline) == resolved, "\(deadline)")
        }
        let marker = { (text: String) in WireJSON.object([(FlowJS.markerKey, .text("number")), ("text", .text(text))]) }
        for refused in [.number(2_147_483_648), marker("Infinity"), marker("NaN"), .text("100"), .text(""), .null,
                        .bool(true), .bool(false), .array([.number(150)]), .object([WireJSON.Member]())] as [WireJSON] {
            let error = #expect(throws: FlowTimerLimitError.self, "\(refused)") {
                try FlowShell.resolveTimeout(refused)
            }
            #expect(error?.localizedDescription == "timeoutMs must be a finite number no greater than 2147483647")
        }
        #expect(try FlowTimer.resolveTimeoutMs(nil) == nil)
        #expect(try FlowTimer.resolveTimeoutMs(0) == nil)
        #expect(try FlowTimer.resolveTimeoutMs(2_147_483_647) == 2_147_483_647)
        for refused in [2_147_483_648, 1e24, .infinity, .nan] as [Double] {
            #expect(throws: FlowTimerLimitError()) { try FlowTimer.resolveTimeoutMs(refused) }
        }
    }

    /// Node's `setTimeout` delay for a deadline: as given, at least 1 ms; and the message
    /// acpx's `TimeoutError` gives — the deadline, or the non-positive `timeoutMs` the command
    /// was given, or 0.
    @Test func aDeadlineRunsAsNodesTimerRunsIt() {
        #expect(FlowShell.timerDelayMs(100) == 100)
        #expect(FlowShell.timerDelayMs(0.5) == 1)
        let message = { (json: WireJSON?) in
            FlowShell.timeoutError(FlowShellExecution(json: .object(json.map { [("timeoutMs", $0)] } ?? [])))
                .localizedDescription
        }
        #expect(message(.number(150)) == "Timed out after 150ms")
        #expect(message(.number(2.5)) == "Timed out after 2.5ms")
        #expect(message(.number(0)) == "Timed out after 0ms")
        #expect(message(.number(-5)) == "Timed out after -5ms")
        #expect(message(.null) == "Timed out after 0ms")
        #expect(message(nil) == "Timed out after 0ms")
    }

    /// A delay past Node's timer limit is no timer: a deadline never is, once resolved; a
    /// heartbeat past it is none (openclaw/acpx#812).
    @Test func aDelayPastNodesTimerLimitIsNoTimer() {
        #expect(FlowTimer.duration(milliseconds: 50) == .nanoseconds(50_000_000))
        #expect(FlowTimer.duration(milliseconds: FlowTimer.maxDelayMs) == .nanoseconds(2_147_483_647_000_000))
        for none in [2_147_483_648, 1e13, 1e24, 1e308, .infinity, .nan] as [Double] {
            #expect(FlowTimer.duration(milliseconds: none) == nil, "\(none)")
        }
        #expect(FlowTimer.duration(milliseconds: -5) == .zero)
    }

    /// acpx: "shell capture rejects invalid limits before spawning".
    @Test func aCaptureLimitIsANonNegativeSafeInteger() throws {
        for limit in [-1, 0.5, .nan, .infinity, 9_007_199_254_740_992] as [Double] {
            #expect(throws: FlowShellError.self, "\(limit)") { try FlowShell.validateMaxBufferBytes(limit) }
        }
        for limit in [nil, 0, 4, 9_007_199_254_740_991] as [Double?] {
            try FlowShell.validateMaxBufferBytes(limit)
        }
    }

    /// acpx's `createShellFailureError`: how the command ended, and its stderr trimmed.
    @Test func aFailureSaysHowTheCommandEnded() {
        #expect(FlowShell.failureMessage(command: "sh", args: [.text("-c"), .text("exit 2")], exitCode: 2, signal: nil,
            stderr: "  boom\n") == "Shell action failed (sh \"-c\" \"exit 2\"): exit 2\nboom")
        #expect(FlowShell.failureMessage(command: "sleep", args: [], exitCode: nil, signal: "SIGTERM", stderr: "")
            == "Shell action failed (sleep): signal SIGTERM")
        #expect(FlowShell.failureMessage(command: "x", args: [], exitCode: nil, signal: nil, stderr: "")
            == "Shell action failed (x): exit null")
    }

    /// acpx: "shell capture stays unlimited by default and limits streams independently".
    @Test func eachStreamHasALimitOfItsOwn() {
        var capture = FlowShellCapture(maxBufferBytes: 4)
        #expect(capture.append(.stdout, Array("aaaa".utf8)) == nil)
        #expect(capture.append(.stderr, Array("bbbb".utf8)) == nil)
        #expect(capture.stdout + capture.stderr == "aaaabbbb")
        #expect(capture.append(.stdout, Array("a".utf8))?.message
            == "Shell action exceeded maxBuffer (4 bytes) on stdout")
        #expect(capture.stdout == "aaaa")
        var unlimited = FlowShellCapture(maxBufferBytes: nil)
        #expect(unlimited.append(.stdout, [UInt8](repeating: 0x78, count: 2 * 1024 * 1024)) == nil)
        #expect(unlimited.stdout.utf8.count == 2 * 1024 * 1024)
        var empty = FlowShellCapture(maxBufferBytes: 0)
        #expect(empty.append(.stdout, []) == nil)
        #expect(empty.append(.stderr, Array("x".utf8)) != nil)
    }

    /// acpx: "shell capture counts split UTF-8 characters without retaining partial
    /// prefixes".
    @Test func aCharacterSplitAcrossChunksIsCountedWhole() {
        var fits = FlowShellCapture(maxBufferBytes: 2)
        #expect(fits.append(.stdout, [0xC3]) == nil)
        #expect(fits.stdout.isEmpty)
        #expect(fits.append(.stdout, [0xA9]) == nil)
        #expect(fits.stdout == "é")
        var tight = FlowShellCapture(maxBufferBytes: 1)
        #expect(tight.append(.stdout, [0xC3]) == nil)
        #expect(tight.append(.stdout, [0xA9]) != nil)
    }

    /// Node's `StringDecoder`: what a chunk leaves unfinished waits for the next; an
    /// ill-formed sequence is `U+FFFD`; the end turns what is left into one.
    @Test func theDecoderHoldsAnUnfinishedCharacter() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode([0x61, 0xE2, 0x82]) == "a")
        #expect(decoder.decode([0xAC, 0x62]) == "€b")
        #expect(decoder.decode([0xF0, 0x9F, 0x98]) == "")
        #expect(decoder.decode([0x80]) == "😀")
        #expect(decoder.decode([0xE2, 0x82, 0x41]) == "\u{FFFD}A")
        #expect(decoder.decode([0xFF, 0x41]) == "\u{FFFD}A")
        #expect(decoder.decode([0xF0, 0x9F]) == "")
        #expect(decoder.end() == "\u{FFFD}")
        #expect(decoder.end().isEmpty)
        #expect(UTF8StreamDecoder.unfinishedTail([0xC3, 0xA9]) == 0)
        #expect(UTF8StreamDecoder.unfinishedTail([0xC3, 0xA9, 0xA9]) == 0)
        #expect(UTF8StreamDecoder.unfinishedTail([0xF0, 0x9F, 0x98]) == 3)
    }
}
