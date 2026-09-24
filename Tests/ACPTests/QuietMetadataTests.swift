@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Quiet output reports a turn's token usage and cost on stderr after the reply, as
/// acpx 0.19.1's quiet formatter does (`flushMetadata`, #104). Every expected line is
/// what acpx printed, or its `formatMetadataNumber` returned, for the same input.
struct QuietMetadataTests {
    private func json(_ text: String) throws -> WireJSON {
        try #require(WireJSON(parsing: text))
    }

    @Test func usageTakesEachFieldsFirstSpelling() throws {
        #expect(QuietMetadata.usageLine(try json("""
            {"inputTokens":12,"outputTokens":34,"cachedReadTokens":5,"cachedWriteTokens":6,"totalTokens":57}
            """)) == "[acpx] tokens: input=12 output=34 cache_read=5 cache_write=6 total=57")
        #expect(QuietMetadata.usageLine(try json("""
            {"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":1,"cache_creation_input_tokens":2,\
            "total_tokens":10}
            """)) == "[acpx] tokens: input=3 output=4 cache_read=1 cache_write=2 total=10")
        #expect(QuietMetadata.usageLine(try json(#"{"cacheReadInputTokens":7,"cacheCreationInputTokens":8}"#))
            == "[acpx] tokens: cache_read=7 cache_write=8")
        // The first spelling holding a number wins; anything else is passed over.
        #expect(QuietMetadata.usageLine(try json(#"{"inputTokens":1,"input_tokens":2}"#)) == "[acpx] tokens: input=1")
        #expect(QuietMetadata.usageLine(try json(#"{"inputTokens":"x","input_tokens":2}"#)) == "[acpx] tokens: input=2")
        #expect(QuietMetadata.usageLine(try json(#"{"outputTokens":7}"#)) == "[acpx] tokens: output=7")
        #expect(QuietMetadata.usageLine(try json(#"{"used":100}"#)) == nil)
        #expect(QuietMetadata.usageLine(try json("[1]")) == nil)
        #expect(QuietMetadata.usageLine(nil) == nil)
    }

    @Test func costIsANumberAStringOrAnAmount() throws {
        #expect(QuietMetadata.costLine(try json("0.0042")) == "[acpx] cost: 0.0042")
        #expect(QuietMetadata.costLine(try json(#"" $0.01 ""#)) == "[acpx] cost: $0.01")
        #expect(QuietMetadata.costLine(try json(#""   ""#)) == nil)
        #expect(QuietMetadata.costLine(try json(#"{"amount":1.5,"currency":" USD "}"#)) == "[acpx] cost: 1.5 USD")
        #expect(QuietMetadata.costLine(try json(#"{"value":2}"#)) == "[acpx] cost: 2")
        #expect(QuietMetadata.costLine(try json(#"{"total":3,"currency":""}"#)) == "[acpx] cost: 3")
        #expect(QuietMetadata.costLine(try json(#"{"amount":"1","value":4}"#)) == "[acpx] cost: 4")
        #expect(QuietMetadata.costLine(try json(#"{"currency":"USD"}"#)) == nil)
        #expect(QuietMetadata.costLine(try json("true")) == nil)
        #expect(QuietMetadata.costLine(nil) == nil)
    }

    /// `String(Number(value.toFixed(8)))` for anything but an integer: rounded half up at
    /// the eighth place on the exact value — `0.001953125` is exactly halfway — and in
    /// JavaScript's notation.
    @Test(arguments: [
        (12, "12"), (1.5, "1.5"), (0.0042, "0.0042"), (0.001953125, "0.00195313"),
        (-0.001953125, "-0.00195313"), (123_456_789.123456789, "123456789.12345679"), (0.1 + 0.2, "0.3"),
        (1e-9, "0"), (5e-9, "1e-8"), (4.9e-9, "0"), (0.999999995, "1"), (1.23456789123, "1.23456789"),
        (2.5e-7, "2.5e-7"), (1e21, "1e+21"), (1e22, "1e+22")
    ] as [(Double, String)])
    func numbersAreFormattedAsAcpxFormatsThem(value: Double, expected: String) {
        #expect(QuietMetadata.number(value) == expected)
    }

    /// `exec` reads the prompt response off the wire and reports its usage after the
    /// reply — in quiet output only.
    @Test(.enabled(if: mockPythonAvailable))
    func quietExecReportsTheResponsesUsage() async throws {
        let command = try #require(mockCommand())
        for format in ["quiet", "text", "json"] {
            let (out, err) = await withIsolatedStore {
                let capture = Console.Capture()
                _ = Console.$capture.withValue(capture) {
                    runCommandLine(["--format", format, "--approve-all", "--agent", command, "exec", "hi"])
                }
                return (capture.out, capture.err)
            }
            let line = "[acpx] tokens: input=12 output=34 cache_read=5 cache_write=6 total=57\n"
            #expect(err.contains(line) == (format == "quiet"), "\(format)")
            if format == "quiet" { #expect(out.hasPrefix("Hello from the mock agent!")) }
        }
    }

    /// The daemon sends the prompt response's usage and cost with the turn's end, in the
    /// shape the agent sent them, for `prompt` to report.
    @Test(.enabled(if: mockPythonAvailable))
    func aDaemonTurnsEndCarriesItsUsage() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: command, cwd: NSTemporaryDirectory())
            let client = DaemonToolsTests.CallingClient()
            try await DaemonToolsTests().prompt(daemon, id, text: "hi", client: client)
            let ended = try #require(client.logs.lazy.compactMap { try? $0.decoded(TurnEndedEvent.self) }.first)
            #expect(ended.usage == .object([
                "inputTokens": .integer(12), "outputTokens": .integer(34), "cachedReadTokens": .integer(5),
                "cachedWriteTokens": .integer(6), "totalTokens": .integer(57)
            ]))
            #expect(ended.cost == nil)

            let box = StopReasonBox()
            await box.set(ended)
            #expect(await box.usage == ended.usage)
        }
    }
}
