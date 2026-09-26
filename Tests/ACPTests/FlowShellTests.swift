@testable import ACPXFlows
import Foundation
import SwiftACP
import Testing

/// acpx's shell action rules that need no process (`test/flows-shell.test.ts`, v0.19.3),
/// and the UTF-8 decoding Node's `setEncoding("utf8")` does for its capture.
struct FlowShellTests {
    /// acpx: "renderShellCommand quotes arguments consistently".
    @Test func aCommandIsShownWithItsArgumentsQuoted() {
        #expect(FlowShell.renderCommand("echo", ["hello", "two words"]) == #"echo "hello" "two words""#)
        #expect(FlowShell.renderCommand("ls", []) == "ls")
        #expect(FlowShell.renderCommand("printf", ["a\"b\n"]) == #"printf "a\"b\n""#)
    }

    /// acpx: "formatShellActionSummary prefixes rendered commands".
    @Test func theSummaryPrefixesTheCommand() {
        #expect(FlowShell.summary("git", ["status", "--short"]) == #"shell: git "status" "--short""#)
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
        #expect(FlowShell.failureMessage(command: "sh", args: ["-c", "exit 2"], exitCode: 2, signal: nil,
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
