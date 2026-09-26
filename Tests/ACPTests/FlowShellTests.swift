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

    /// acpx: "resolveShellActionTimeoutMs treats non-positive as no deadline" — and, as its
    /// JavaScript compares `timeoutMs > 0`, a string, boolean or list that converts to a
    /// positive number is a deadline too, kept as given.
    @Test func onlyAPositiveTimeoutIsADeadline() {
        for none in [nil, .null, .number(0), .number(-1), .number(.nan), .text(""), .text("abc"), .text("-5"),
                     .bool(false), .array([]), .array([.number(1), .number(2)]), .object([WireJSON.Member]())]
            as [WireJSON?] {
            #expect(FlowShell.resolveTimeout(none) == nil, "\(String(describing: none))")
        }
        for deadline in [.number(50), .number(.infinity), .number(0.5), .text("100"), .text(" 0x10 "), .bool(true),
                         .array([.number(150)]), .array([.text("7")])] as [WireJSON] {
            #expect(FlowShell.resolveTimeout(deadline) == deadline, "\(deadline)")
        }
    }

    /// Node's `setTimeout` delay for a deadline: its number, at least 1 ms; and the message
    /// acpx's `TimeoutError` gives, the value as `${…}` writes it.
    @Test func aDeadlineRunsAsNodesTimerRunsIt() {
        #expect(FlowShell.timerDelayMs(.text("100")) == 100)
        #expect(FlowShell.timerDelayMs(.bool(true)) == 1)
        #expect(FlowShell.timerDelayMs(.number(0.5)) == 1)
        #expect(FlowShell.timerDelayMs(.array([.number(150)])) == 150)
        let message = { (json: WireJSON) in
            FlowShell.timeoutError(FlowShellExecution(json: .object([("timeoutMs", json)]))).localizedDescription
        }
        #expect(message(.text("100")) == "Timed out after 100ms")
        #expect(message(.bool(true)) == "Timed out after truems")
        #expect(message(.array([.number(150)])) == "Timed out after 150ms")
        #expect(message(.number(2.5)) == "Timed out after 2.5ms")
        #expect(message(.text("abc")) == "Timed out after abcms")
        #expect(message(.null) == "Timed out after 0ms")
    }

    /// A delay no clock can hold is no timer: one past ``FlowTimer/maxDelayMs`` outlives any
    /// run, and much further `Duration.milliseconds` traps.
    @Test func aDelayNoClockCanHoldIsNoTimer() {
        #expect(FlowTimer.duration(milliseconds: 50) == .nanoseconds(50_000_000))
        #expect(FlowTimer.duration(milliseconds: 3_000_000_000) == .nanoseconds(3_000_000_000_000_000))
        #expect(FlowTimer.duration(milliseconds: FlowTimer.maxDelayMs) == .nanoseconds(1_000_000_000_000_000_000))
        for none in [1e13, 1e24, 1e308, .infinity, .nan] as [Double] {
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
