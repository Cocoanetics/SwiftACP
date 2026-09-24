@testable import SwiftACP
import Foundation
import Testing

/// The rules acpx's `TerminalManager` applies to a request and to a command's output,
/// checked without running anything (#82). Expected values are acpx 0.19.1's.
struct TerminalOutputTests {
    // MARK: - Limits

    @Test func aRequestNamingNoLimitKeeps64KiB() {
        #expect(TerminalOutputLimit.resolve(requested: nil, ceiling: nil) == 65_536)
    }

    @Test func aNegativeLimitKeepsNothing() {
        #expect(TerminalOutputLimit.resolve(requested: -5, ceiling: nil) == 0)
    }

    @Test func theHostCeilingCapsWhateverIsAsked() {
        #expect(TerminalOutputLimit.resolve(requested: 10, ceiling: 3) == 3)
        #expect(TerminalOutputLimit.resolve(requested: nil, ceiling: 3) == 3)
        #expect(TerminalOutputLimit.resolve(requested: 2, ceiling: 3) == 2)
    }

    /// `ACPX_TERMINAL_MAX_OUTPUT_BYTES`, trimmed: unset, blank and `0` are no ceiling.
    @Test(arguments: [
        (nil, nil), ("", nil), (" \t", nil), ("0", nil), ("000", nil), ("3", 3), (" 4 ", 4), ("007", 7),
        ("9007199254740991", 9_007_199_254_740_991)
    ] as [(String?, Int?)])
    func ceilingsAcpxAccepts(raw: String?, expected: Int?) throws {
        let environment = raw.map { ["ACPX_TERMINAL_MAX_OUTPUT_BYTES": $0] } ?? [:]
        #expect(try TerminalOutputLimit.ceiling(environment: environment) == expected)
    }

    /// Anything but decimal digits naming a safe integer stops acpx from starting.
    @Test(arguments: ["abc", "-1", "+3", "1e3", "1.5", "3 4", "٣", "9007199254740992", "99999999999999999999"])
    func ceilingsAcpxRefuses(raw: String) {
        #expect(throws: TerminalOutputCeilingError()) {
            try TerminalOutputLimit.ceiling(environment: ["ACPX_TERMINAL_MAX_OUTPUT_BYTES": raw])
        }
        #expect(TerminalOutputCeilingError().localizedDescription
            == "ACPX_TERMINAL_MAX_OUTPUT_BYTES must be a non-negative safe integer; zero disables the host ceiling")
    }

    // MARK: - Retained output

    /// The newest bytes, never starting inside a character: of `héllo wörld`'s last five
    /// bytes, `ö` is two.
    @Test func truncationKeepsTheNewestBytesOnACharacterBoundary() {
        let output = TerminalOutput(limit: 5)
        output.append(Array("héllo wörld".utf8))
        #expect(output.read() == ("örld", true))
    }

    /// Once anything was dropped, a later chunk that pushes out a character's first byte
    /// takes its continuation bytes with it.
    @Test func laterChunksKeepTheBoundaryToo() {
        let output = TerminalOutput(limit: 3)
        output.append(Array("ab".utf8))
        #expect(output.read() == ("ab", false))
        output.append([0xC3])
        output.append([0xA9])
        #expect(output.read() == ("bé", true))
        output.append(Array("xy".utf8))
        #expect(output.read() == ("xy", true))
    }

    @Test func aZeroLimitKeepsNothingButSaysSo() {
        let output = TerminalOutput(limit: 0)
        #expect(output.read() == ("", false))
        output.append([])
        #expect(output.read() == ("", false))
        output.append(Array("abc".utf8))
        #expect(output.read() == ("", true))
    }

    /// Node's `toString("utf8")`: each invalid byte is a replacement character.
    @Test func invalidUTF8ReadsAsNodeReadsIt() {
        let output = TerminalOutput(limit: 100)
        output.append([0xFF, 0xFE] + Array("ok".utf8))
        #expect(output.read().text == "\u{FFFD}\u{FFFD}ok")
    }

    // MARK: - Wire shapes

    /// The schema's `number`, rounded as `Math.round` rounds it.
    @Test(arguments: [(2.6, 3), (2.5, 3), (-2.5, -2), (5.0, 5), (0.4, 0)])
    func fractionalLimitsAreRounded(limit: Double, expected: Int) throws {
        let json = #"{"sessionId":"s","command":"c","outputByteLimit":\#(limit)}"#
        let request = try JSONDecoder().decode(CreateTerminalRequest.self, from: Data(json.utf8))
        #expect(request.outputByteLimit == expected)
    }

    @Test func aNullLimitIsNoLimit() throws {
        let json = #"{"sessionId":"s","command":"c","outputByteLimit":null}"#
        let request = try JSONDecoder().decode(CreateTerminalRequest.self, from: Data(json.utf8))
        #expect(request.outputByteLimit == nil)
        #expect(request.args == nil)
    }

    /// acpx always sends both members of an exit status, `null` when they do not apply.
    @Test func exitStatusesCarryBothMembers() throws {
        #expect(try encoded(TerminalExitStatus(exitCode: 0)) == #"{"exitCode":0,"signal":null}"#)
        #expect(try encoded(WaitForTerminalExitResponse(signal: "SIGTERM"))
            == #"{"exitCode":null,"signal":"SIGTERM"}"#)
        // Before the command exits there is no status at all.
        #expect(try encoded(TerminalOutputResponse(output: "", truncated: false))
            == #"{"output":"","truncated":false}"#)
    }

    private func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - The command line a confirmation shows

    /// acpx's `toCommandLine`: each argument as `JSON.stringify` quotes it.
    @Test func argumentsAreQuotedAsJSONStringifyQuotesThem() {
        let line = TerminalApproval.commandLine(command: "echo", args: ["a b", "c\"d", "é", "t\tn\n", "\u{1}", "\\"])
        #expect(line == #"echo "a b" "c\"d" "é" "t\tn\n" "\u0001" "\\""#)
    }

    @Test func withoutArgumentsItIsTheCommandAlone() {
        #expect(TerminalApproval.commandLine(command: "echo 'x' | cat", args: nil) == "echo 'x' | cat")
        #expect(TerminalApproval.commandLine(command: "ls", args: []) == "ls")
    }
}
