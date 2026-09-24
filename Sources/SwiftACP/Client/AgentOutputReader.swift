import Foundation
import JSONFoundation

/// Reading what an agent writes to its stdout the way acpx's `createNdJsonMessageStream`
/// does (`src/acp/ndjson-stream.ts`):
///
/// - a line ends at LF; the bytes of an unfinished line are kept until it does, and
///   dropped if the output ends first;
/// - each line is decoded as UTF-8 (a bad sequence becomes U+FFFD, as `TextDecoder`
///   makes it), trimmed as JavaScript trims, and skipped when empty — or, for
///   `qodercli`, when it is one of the notices it prints on stdout;
/// - a line is parsed as `JSON.parse` parses it: an object is a message, any other
///   JSON value is dropped without a word, and text that is no JSON is reported
///   (``Line/unparseable(_:_:)``) and skipped;
/// - no line may run past `maxMessageBytes` (``AcpMessageLimit``): the whole read
///   fails as soon as one does, even before its LF arrives.
struct AgentOutputReader {
    /// What one complete line of output came to.
    enum Line {
        /// A message, with the line's bytes as trimmed — what the wire shows.
        case message(JSONRPCMessage, Data)
        /// A JSON object that is no JSON-RPC message: seen on the wire, but nothing to
        /// dispatch.
        case object(Data)
        /// Text `JSON.parse` refuses: acpx logs it with the error and reads on.
        case unparseable(String, WireJSON.SyntaxError)
    }

    private let ignoresNotices: Bool
    private let maxMessageBytes: Int?
    /// How much of the current line has been read — acpx's `retainedBytes`.
    private var retained = 0
    /// The current line's bytes, waiting for its LF.
    private var fragment: [UInt8] = []

    /// - Parameters:
    ///   - agentCommand: the command the agent was started with, for its quirks.
    ///   - maxMessageBytes: the longest line allowed, `nil` for no limit.
    init(agentCommand: String, maxMessageBytes: Int?) {
        ignoresNotices = AgentCommandQuirks(agentCommand).isQoder
        self.maxMessageBytes = maxMessageBytes
    }

    /// Take in the next chunk of output and return what the lines it completed came
    /// to. Throws ``AcpMessageLimitError`` once a line is longer than allowed.
    mutating func push(_ chunk: [UInt8]) throws -> [Line] {
        if let maxMessageBytes {
            retained = try Self.countLineBytes(chunk, retained: retained, limit: maxMessageBytes)
        }
        var lines: [Line] = []
        var start = 0
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            fragment += chunk[start..<newline]
            if let line = read(fragment) { lines.append(line) }
            fragment = []
            start = newline + 1
        }
        fragment += chunk[start...]
        return lines
    }

    /// acpx's `countLineBytes`: the bytes of the current line, counted chunk by chunk.
    static func countLineBytes(_ chunk: [UInt8], retained: Int, limit: Int) throws -> Int {
        var retained = retained
        var start = 0
        while start < chunk.count {
            let newline = chunk[start...].firstIndex(of: 0x0A)
            retained += (newline ?? chunk.count) - start
            if retained > limit { throw AcpMessageLimitError(limit: limit) }
            guard let newline else { return retained }
            retained = 0
            start = newline + 1
        }
        return retained
    }

    /// acpx's `enqueueNdJsonLine`. Only an object is looked at twice — decoded as a
    /// message, then, if it is none, parsed as `JSON.parse` would to tell a stray
    /// object from text that is no JSON.
    private func read(_ bytes: [UInt8]) -> Line? {
        let trimmed = String(decoding: bytes, as: UTF8.self).trimmedLikeJavaScript
        guard !trimmed.isEmpty, !(ignoresNotices && AgentCommandQuirks.qoderNotices.contains(trimmed)) else {
            return nil
        }
        let data = Data(trimmed.utf8)
        if trimmed.hasPrefix("{"), let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) {
            return .message(message, data)
        }
        do {
            guard case .object = try WireJSON.parse(trimmed) else { return nil }
            return .object(data)
        } catch let error as WireJSON.SyntaxError {
            return .unparseable(trimmed, error)
        } catch {
            return nil
        }
    }
}

/// What acpx does differently for an agent, going by the command that starts it.
struct AgentCommandQuirks {
    /// Whether the agent is `qodercli` — acpx's `basenameToken` of its command.
    let isQoder: Bool

    init(_ agentCommand: String) {
        isQoder = AgentRegistry.splitCommandLine(agentCommand).first.map(Self.basenameToken) == "qodercli"
    }

    /// acpx's `QODER_BENIGN_STDOUT_LINES`: what `qodercli` prints on stdout as it stops.
    static let qoderNotices: Set<String> = [
        "Received interrupt signal. Cleaning up resources...",
        "Cleanup completed. Exiting..."
    ]

    /// How long a closing agent gets to exit on its own once its stdin ends — acpx's
    /// `resolveAgentCloseAfterStdinEndMs`: 100 ms, `qodercli` 750.
    var closeAfterStdinEnd: Duration { isQoder ? .milliseconds(750) : .milliseconds(100) }

    /// acpx's `basenameToken`: the lowercased file name with a Windows executable suffix
    /// dropped. Node's `path.basename` is platform-dependent, so a backslash only
    /// separates on Windows.
    static func basenameToken(_ value: String) -> String {
        var name = (value as NSString).lastPathComponent
        #if os(Windows)
        if let backslash = name.lastIndex(of: "\\") {
            name = String(name[name.index(after: backslash)...])
        }
        #endif
        name = name.lowercased()
        for suffix in [".cmd", ".exe", ".bat"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
