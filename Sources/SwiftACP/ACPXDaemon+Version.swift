import Foundation
import JSONFoundation
import SwiftMCP

// The version acpxd reports, which acpx checks before it works through a daemon (#162).
extension ACPXDaemon {
    /// The fingerprint of the daemon's tools (``interfaceFingerprint(of:)``), pinned by a test
    /// (`DaemonVersionTests`): change a tool — add one, drop or rename a parameter, change what
    /// it takes or returns — and the test says what to put here.
    static let interfaceFingerprint = "bb725ff28f3dd429"

    /// The version acpxd reports in MCP's `serverInfo`: SwiftACP's, and its tools'. acpx works
    /// only through a daemon reporting its own: an MCP tool drops the arguments it does not
    /// declare without a word, so a daemon of another build would drop what acpx has learned
    /// to send since — timeouts, retries, a TTL (#162).
    public static let version = "\(ACPVersion.current)+\(interfaceFingerprint)"

    public nonisolated var serverVersion: String { Self.version }

    /// A fingerprint of `tools`, as a daemon lists them: each one's name, and the schemas of what
    /// it takes and returns — what they say of themselves, their descriptions, left out. The
    /// 64-bit FNV-1a hash of their JSON, keys sorted, in hex.
    static func interfaceFingerprint(of tools: [MCPTool]) -> String {
        let interface: [JSONValue] = tools.sorted { $0.name < $1.name }.map { tool in
            var entry: [String: JSONValue] = ["name": .string(tool.name)]
            entry["inputSchema"] = (try? JSONValue(encoding: tool.inputSchema)).map { withoutDescriptions($0) }
            entry["outputSchema"] = tool.outputSchema.flatMap { try? JSONValue(encoding: $0) }
                .map { withoutDescriptions($0) }
            return .object(entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (try? encoder.encode(JSONValue.array(interface))) ?? Data() {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// `schema` without its `description`s — though with every property, whatever its name.
    private static func withoutDescriptions(_ schema: JSONValue, naming properties: Bool = false) -> JSONValue {
        switch schema {
        case .object(let members):
            var kept: [String: JSONValue] = [:]
            for (key, value) in members where properties || key != "description" {
                kept[key] = withoutDescriptions(value, naming: !properties && key == "properties")
            }
            return .object(kept)
        case .array(let items):
            return .array(items.map { withoutDescriptions($0) })
        default:
            return schema
        }
    }
}
