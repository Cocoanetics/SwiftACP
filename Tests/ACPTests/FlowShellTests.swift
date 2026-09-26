@testable import ACPXFlows
import Foundation
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

    /// acpx: "resolveShellActionTimeoutMs treats non-positive as no deadline".
    @Test func onlyAPositiveTimeoutIsADeadline() {
        #expect(FlowShell.resolveTimeoutMs(nil) == nil)
        #expect(FlowShell.resolveTimeoutMs(0) == nil)
        #expect(FlowShell.resolveTimeoutMs(-1) == nil)
        #expect(FlowShell.resolveTimeoutMs(.nan) == nil)
        #expect(FlowShell.resolveTimeoutMs(50) == 50)
        #expect(FlowShell.resolveTimeoutMs(.infinity) == .infinity)
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
