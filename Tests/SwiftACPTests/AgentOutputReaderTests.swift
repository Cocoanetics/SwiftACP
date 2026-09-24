import Foundation
@testable import SwiftACP
import Testing

/// acpx's `createNdJsonMessageStream` read side (`src/acp/ndjson-stream.ts`), rule by
/// rule, on `AgentOutputReader`.
@Suite struct AgentOutputReaderTests {
    /// What the reader made of `chunks`, one description per line it returned.
    static func read(
        _ chunks: [String], agentCommand: String = "agent", limit: Int? = nil
    ) throws -> [String] {
        var reader = AgentOutputReader(agentCommand: agentCommand, maxMessageBytes: limit)
        return try chunks.flatMap { try reader.push(Array($0.utf8)) }.map { line in
            switch line {
            case .message(_, let body): "message " + String(decoding: body, as: UTF8.self)
            case .object(let body): "object " + String(decoding: body, as: UTF8.self)
            case .unparseable(let text, let error): "unparseable \(text): \(error)"
            }
        }
    }

    static let ping = #"{"jsonrpc":"2.0","method":"ping"}"#

    @Test func aLineEndsAtItsLineFeedHoweverItArrives() throws {
        let (head, tail) = (String(Self.ping.prefix(10)), String(Self.ping.dropFirst(10)))
        #expect(try Self.read([head, tail + "\n" + Self.ping, "\n"]) == [
            "message " + Self.ping, "message " + Self.ping
        ])
    }

    /// An unfinished line is dropped with the output: acpx closes the stream without it.
    @Test func anUnfinishedLineIsNotRead() throws {
        #expect(try Self.read([Self.ping]) == [])
    }

    /// Trimmed as JavaScript trims — a carriage return, a BOM, a no-break space — and
    /// skipped when nothing is left.
    @Test func linesAreTrimmedAsJavaScriptTrims() throws {
        #expect(try Self.read(["\u{FEFF} \(Self.ping)\u{00A0}\r\n", "   \n", "\n"]) == ["message " + Self.ping])
    }

    /// Only an object is a message: every other JSON value is dropped without a word —
    /// a batch too — and an object that is no JSON-RPC message is read but not one.
    @Test func onlyObjectsAreMessages() throws {
        let batch = "[\(Self.ping)]"
        #expect(try Self.read(["42\n\"x\"\nnull\ntrue\n[1]\n\(batch)\n{\"stray\":true}\n"]) == [
            #"object {"stray":true}"#
        ])
    }

    /// Text that is no JSON is reported with `JSON.parse`'s error, in V8's words.
    @Test func textThatIsNoJSONIsReported() throws {
        #expect(try Self.read(["hello\n", "{oops\n"]) == [
            #"unparseable hello: Unexpected token 'h', "hello" is not valid JSON"#,
            "unparseable {oops: Expected property name or '}' in JSON at position 1 (line 1 column 2)"
        ])
    }

    /// `qodercli`'s notices on stdout are skipped — for `qodercli` alone.
    @Test func qodercliNoticesAreSkipped() throws {
        let notice = "Cleanup completed. Exiting...\n"
        #expect(try Self.read([notice], agentCommand: "/opt/bin/QoderCLI.exe --acp") == [])
        #expect(try Self.read([notice], agentCommand: "agent").count == 1)
    }

    /// acpx's `countLineBytes`: a line's bytes, LF excluded, however it is split up; a
    /// line may be as long as the limit, and one longer fails before its LF arrives.
    @Test func aLineMayNotRunPastTheLimit() throws {
        let fits = String(repeating: "a", count: 10)
        #expect(try Self.read([String(fits.prefix(4)), fits.dropFirst(4) + "\n" + fits + "\n"], limit: 10).count == 2)
        #expect(throws: AcpMessageLimitError(limit: 10)) {
            _ = try Self.read([fits, "b"], limit: 10)
        }
        #expect(throws: AcpMessageLimitError(limit: 10)) {
            _ = try Self.read(["\(fits)b\n"], limit: 10)
        }
    }

    /// acpx's `readMaxAcpMessageBytes`.
    @Test func theLimitIsReadAsAcpxReadsIt() throws {
        func bytes(_ value: String?) throws -> Int? {
            try AcpMessageLimit.bytes(environment: value.map { ["ACPX_MAX_ACP_MESSAGE_BYTES": $0] } ?? [:])
        }
        #expect(try bytes(nil) == 67_108_864)
        #expect(try bytes("  ") == 67_108_864)
        #expect(try bytes(" 1024 ") == 1024)
        #expect(try bytes("007") == 7)
        #expect(try bytes("0") == nil)
        #expect(try bytes("9007199254740991") == 9_007_199_254_740_991)
        for refused in ["-1", "1.5", "abc", "1e3", "9007199254740992"] {
            #expect(throws: AcpMessageLimitSettingError()) { _ = try bytes(refused) }
        }
        #expect(AcpMessageLimitSettingError().description
            == "ACPX_MAX_ACP_MESSAGE_BYTES must be a non-negative safe integer; zero is unlimited")
    }

    /// acpx's `captureStartupStderr` and `summarizeStartupStderr`: the last 8,192
    /// characters, each run of whitespace one space.
    @Test func theAgentsStderrIsKeptAsAcpxKeepsIt() {
        var tail = StderrTail()
        #expect(tail.summary == nil)
        tail.append(Array("  first\n\tsecond  ".utf8))
        #expect(tail.summary == "first second")
        tail.append(Array(String(repeating: "x", count: 9000).utf8))
        #expect(tail.summary == String(repeating: "x", count: 8192))
    }
}
