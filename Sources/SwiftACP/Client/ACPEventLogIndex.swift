import Foundation

/// The direction of a recorded ACP body, relative to the client.
public enum ACPEventLogDirection: String, Codable, Sendable {
    case inbound
    case outbound
}

/// Shared recording/replay format, independent of the desktop-only writer.
/// JSON integers encode `version`, UInt64 `offset`/`length`, and UInt32 `crc32` (decimal,
/// not hex). `timestamp` is UTC ISO-8601 with exactly three fractional digits;
/// `direction` is omitted when unknown. Every record ends with one LF.
struct ACPEventLogIndexRecord: Codable, Equatable, Sendable {
    var version = 1
    let offset: UInt64
    let length: UInt64
    let crc32: UInt32
    let timestamp: String
    let direction: ACPEventLogDirection?

    init(offset: UInt64, bytes: Data, timestamp: Date, direction: ACPEventLogDirection?) {
        self.offset = offset
        length = UInt64(bytes.count)
        crc32 = Self.checksum(bytes)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: timestamp)
        self.direction = direction
    }

    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// CRC-32/IEEE (reflected polynomial 0xEDB88320, initial/final XOR 0xFFFFFFFF).
    static func checksum(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320)
            }
        }
        return crc ^ UInt32.max
    }
}
