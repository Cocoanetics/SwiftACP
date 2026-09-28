import Foundation
import SwiftACP

/// The owner acpx 0.19.3 names in a session lock (`createLockOwner`, `lock-owner.ts`): this
/// process's pid and its birth as acpx records one on macOS (`processIdentity`, kind
/// `posix-lstart`: when the process started, to the second, in UTC — what `ps -o lstart`
/// prints with `TZ=UTC`). Written in acpx's own form, an acpx process judges a SwiftACP
/// holder as it judges one of its own, and SwiftACP judges acpx's holders as acpx does.
struct AcpxLockOwner: Sendable {
    let pid: Int32
    /// The `posix-lstart` birth; `nil` when it could not be read, and then left out.
    let birth: String?

    /// This process, as `createLockOwner` makes it.
    static let current = AcpxLockOwner(pid: getpid(), birth: birth(of: getpid()))

    /// `owner.payload`: `{pid, processIdentity}`, in that order.
    var payload: [WireJSON.Member] {
        var members = [WireJSON.Member("pid", .number(Double(pid)))]
        if let birth {
            members.append(WireJSON.Member(
                "processIdentity", .object([.init("kind", .text("posix-lstart")), .init("value", .text(birth))])))
        }
        return members
    }

    /// Whether the owner `payload` names has exited, as acpx's `owner.hasExited` decides it:
    /// only a pid acpx would take (`lockOwnerPid`) can have, and only once it is `gone`
    /// (`observeProcessIncarnation`): no process has the pid, or one born at another time
    /// does. A birth recorded in a form only another platform reads (`linux-proc`,
    /// `windows-creation`) says nothing, nor does a live pid whose birth was not recorded.
    static func hasExited(_ payload: WireJSON?) -> Bool {
        guard let pid = pid(in: payload) else { return false }
        switch payload?["processIdentity"].flatMap(identityKind) {
        case "linux-proc", "windows-creation":
            return false
        case "posix-lstart":
            if isDefinitelyDead(pid) { return true }
            guard let observed = birth(of: pid) else { return isDefinitelyDead(pid) }
            return observed != payload?["processIdentity"]?["value"]?.stringValue
        default:
            return isDefinitelyDead(pid)
        }
    }

    /// acpx's `lockOwnerPid`: a positive safe integer under `pid`, or none.
    static func pid(in payload: WireJSON?) -> Int32? {
        guard case .number(let value)? = payload?["pid"], value > 0, value == value.rounded(),
            value <= Double(Int32.max)
        else { return nil }
        return Int32(value)
    }

    /// acpx's `isProcessDefinitelyDead`: `kill(pid, 0)` fails with `ESRCH` — never this process.
    static func isDefinitelyDead(_ pid: Int32) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    /// `pid`'s birth as acpx reads it on macOS: its start, to the second, in UTC.
    static func birth(of pid: Int32) -> String? {
        ProcessBirth.date(of: pid).map { format(Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down))) }
    }

    /// The kind of `identity`, when acpx's `parseProcessBirthIdentity` takes it: a timestamp
    /// in its canonical form — `posix-lstart` to the second, `windows-creation` to 100 ns —
    /// or a `linux-proc` birth with its boot, namespaces and start.
    private static func identityKind(_ identity: WireJSON) -> String? {
        guard let kind = identity["kind"]?.stringValue else { return nil }
        switch kind {
        case "posix-lstart", "windows-creation":
            let fraction = kind == "posix-lstart" ? 3 : 7
            guard let value = identity["value"]?.stringValue, isCanonicalBirth(value, fraction: fraction) else {
                return nil
            }
            return kind == "posix-lstart" && !value.hasSuffix(".000Z") ? nil : kind
        case "linux-proc":
            guard let boot = identity["bootId"]?.stringValue, isBootId(boot),
                let pidSpace = identity["pidNamespace"]?.stringValue, isNamespace(pidSpace, "pid"),
                let timeSpace = identity["timeNamespace"]?.stringValue,
                timeSpace == "unsupported" || isNamespace(timeSpace, "time"),
                let ticks = identity["startTicks"]?.stringValue, isDecimal(ticks)
            else { return nil }
            return kind
        default:
            return nil
        }
    }

    /// `YYYY-MM-DDTHH:MM:SS.<fraction digits>Z`, naming a real moment to the second.
    private static func isCanonicalBirth(_ value: String, fraction: Int) -> Bool {
        let chars = Array(value.utf8)
        guard chars.count == 21 + fraction, chars[19] == UInt8(ascii: "."), chars.last == UInt8(ascii: "Z") else {
            return false
        }
        let digits = Array(0..<4) + [5, 6, 8, 9, 11, 12, 14, 15, 17, 18] + Array(20..<(20 + fraction))
        let separators: [Int: Character] = [4: "-", 7: "-", 10: "T", 13: ":", 16: ":"]
        guard digits.allSatisfy({ (0x30...0x39).contains(chars[$0]) }),
            separators.allSatisfy({ chars[$0.key] == $0.value.asciiValue })
        else { return false }
        let seconds = String(value.prefix(19)) + ".000Z"
        return parse(seconds).map(format) == seconds
    }

    private static func isBootId(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12]
            && groups.allSatisfy { $0.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) } }
    }

    /// `<kind>:[<positive integer>]`.
    private static func isNamespace(_ value: String, _ kind: String) -> Bool {
        guard value.hasPrefix("\(kind):["), value.hasSuffix("]") else { return false }
        let number = value.dropFirst(kind.count + 2).dropLast()
        return isDecimal(String(number)) && number.first != "0"
    }

    private static func isDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
            && (value == "0" || !value.hasPrefix("0"))
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
