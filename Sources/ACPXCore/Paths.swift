import CryptoKit
import Foundation

/// On-disk locations, matching acpx 0.11.0 exactly (`src/session/event-log.ts`,
/// `repository.ts`, `index.ts`, `cli/queue/paths.ts`).
public enum ACPXPaths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// The acpx state directory. Defaults to `~/.acpx`; redirectable via the
    /// `ACPX_HOME` environment variable (so the daemon can run against an isolated
    /// store) and settable directly in tests. The on-disk layout below is
    /// unchanged — only its root moves.
    public nonisolated(unsafe) static var baseDir: URL = defaultBaseDir()

    private static func defaultBaseDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["ACPX_HOME"],
            !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".acpx", isDirectory: true)
    }

    /// `~/.acpx/sessions`
    public static var sessionsDir: URL {
        baseDir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// `~/.acpx/config.json`
    public static var globalConfigPath: URL {
        baseDir.appendingPathComponent("config.json")
    }

    /// `<cwd>/.acpxrc.json`
    public static func projectConfigPath(cwd: String) -> URL {
        URL(fileURLWithPath: cwd).appendingPathComponent(".acpxrc.json")
    }

    /// `~/.acpx/sessions/<encodeURIComponent(id)>.json`
    public static func sessionRecordPath(_ recordId: String) -> URL {
        sessionsDir.appendingPathComponent("\(safeSessionId(recordId)).json")
    }

    /// `~/.acpx/sessions/index.json`
    public static var sessionIndexPath: URL {
        sessionsDir.appendingPathComponent("index.json")
    }

    /// `~/.acpx/sessions/<id>.stream.ndjson`
    public static func sessionStreamPath(_ recordId: String) -> URL {
        sessionsDir.appendingPathComponent("\(safeSessionId(recordId)).stream.ndjson")
    }

    /// `~/.acpx/sessions/<id>.stream.<segment>.ndjson`
    public static func sessionStreamSegmentPath(_ recordId: String, segment: Int) -> URL {
        sessionsDir.appendingPathComponent("\(safeSessionId(recordId)).stream.\(segment).ndjson")
    }

    /// `~/.acpx/queues`
    public static var queuesDir: URL {
        baseDir.appendingPathComponent("queues", isDirectory: true)
    }

    /// 24-hex-char SHA-256 prefix of the session id (queue key).
    public static func queueKey(_ sessionId: String) -> String {
        shortHash(sessionId, length: 24)
    }

    public static func queueLockPath(_ sessionId: String) -> URL {
        queuesDir.appendingPathComponent("\(queueKey(sessionId)).lock")
    }

    /// Node `path.resolve` semantics: make absolute against `base`, normalize
    /// `.`/`..`, but do NOT resolve symlinks or remap `/private` (unlike
    /// `URL.standardizedFileURL`, which rewrites `/private/tmp`→`/tmp`).
    public static func resolve(_ path: String, base: String) -> String {
        let full = path.hasPrefix("/") ? path : base + "/" + path
        var parts: [String] = []
        for component in full.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return "/" + parts.joined(separator: "/")
    }

    /// SHA-256 hex digest truncated to `length` characters.
    public static func shortHash(_ value: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    /// Replicates JavaScript `encodeURIComponent` — unreserved set is
    /// `A–Z a–z 0–9 - _ . ! ~ * ' ( )`; everything else is %XX (uppercase).
    public static func safeSessionId(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: encodeURIComponentAllowed) ?? id
    }

    private static let encodeURIComponentAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()
}
