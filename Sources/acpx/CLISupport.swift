import ACPXCore
import Foundation
import SwiftACP
import JSONFoundation

/// Process exit codes (acpx `EXIT_CODES`).
enum ExitCodes {
    static let success: Int32 = 0
    static let error: Int32 = 1
    static let usage: Int32 = 2
    static let timeout: Int32 = 3
    static let noSession: Int32 = 4
    static let permissionDenied: Int32 = 5
    static let interrupted: Int32 = 130
}

/// The exit code for a failure's output code — acpx's `exitCodeForOutputErrorCode`.
func exitCode(forOutputCode code: String) -> Int32 {
    switch code {
    case "USAGE": return ExitCodes.usage
    case "TIMEOUT": return ExitCodes.timeout
    case "NO_SESSION": return ExitCodes.noSession
    case "PERMISSION_DENIED", "PERMISSION_PROMPT_UNAVAILABLE": return ExitCodes.permissionDenied
    default: return ExitCodes.error
    }
}

/// An operational failure (non-usage). Printed as `<message>` to stderr, exit 1
/// by default. Mirrors acpx's thrown `Error` → top-level handler.
struct CLIError: Error {
    var message: String
    var code: Int32
    init(_ message: String, code: Int32 = ExitCodes.error) {
        self.message = message
        self.code = code
    }
}

/// A `commander.InvalidArgumentError` equivalent — printed as `error: <message>`
/// to stderr, exit code 2 (USAGE).
/// A commander-style parse failure: a bad option, a missing argument, an invalid
/// value. acpx prints `error: <message>`, a blank line and the command's full
/// help screen to stderr, then exits 1 — commander's `showHelpAfterError()`.
///
/// `usage` is the help screen, attached by ``Router`` once the command path is
/// known (the scanner that throws these cannot know it). It is separate from
/// acpx's `EXIT_CODES.USAGE` (2), which is for *runtime* errors carrying a
/// `USAGE` output code, not for argv parsing.
struct UsageError: Error {
    /// Which command commander was parsing for. A global option is declared on
    /// the root, so its rejection shows the *root* help and exits 2; a
    /// subcommand's own option shows that command's help and exits 1.
    enum Scope {
        case root
        case command
    }

    var message: String
    var usage: String?
    var scope: Scope = .command

    init(_ message: String, usage: String? = nil, scope: Scope = .command) {
        self.message = message
        self.usage = usage
        self.scope = scope
    }

    /// `error: option '-f, --file <path>' argument missing`
    static func argumentMissing(_ term: String) -> UsageError {
        UsageError("option '\(term)' argument missing")
    }

    /// `error: option '--config-option <key=value>' argument 'x' is invalid. <reason>`
    static func invalidArgument(_ term: String, _ value: String, _ reason: String) -> UsageError {
        UsageError("option '\(term)' argument '\(value)' is invalid. \(reason)")
    }
}

/// A "no session" failure (exit 4). Message printed verbatim to stderr.
struct NoSessionError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

// MARK: - JSON output

/// Encoder for `--format json` output: the camelCase model shape, compact, with
/// keys sorted for deterministic output and slashes left unescaped.
let jsonOutputEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// Compact JSON string for any `Encodable` (records, config, `JSONValue` envelopes).
func jsonString<E: Encodable>(_ value: E) -> String {
    (try? String(decoding: jsonOutputEncoder.encode(value), as: UTF8.self)) ?? "null"
}

/// A JSON object as acpx builds one: members in the order given, as a JavaScript object
/// literal keeps them. A `nil` member is left out, the way `JSON.stringify` leaves out
/// an `undefined` property; `.null` is printed.
func jsonObject(_ pairs: [(String, JSONValue?)]) -> WireJSON {
    .object(pairs.compactMap { key, value in value.map { WireJSON.Member(key, WireJSON($0)) } })
}

/// ``jsonObject(_:)`` for members that are documents themselves.
func jsonObject(_ pairs: [(String, WireJSON?)]) -> WireJSON {
    .object(pairs.compactMap { key, value in value.map { WireJSON.Member(key, $0) } })
}

extension WireJSON {
    static func integer(_ value: Int) -> WireJSON { .number(Double(value)) }

    /// `JSON.stringify(value)`: how acpx prints a document in `--format json`.
    func compact() -> String { stringified }

    /// `JSON.stringify(value, null, 2)`: how acpx prints one for a reader (`config show`).
    func pretty() -> String { stringified(indent: 2) }
}

/// The physical working directory (resolves symlinks like Node's `process.cwd()`).
func physicalCWD() -> String {
    guard let pointer = getcwd(nil, 0) else { return FileManager.default.currentDirectoryPath }
    defer { free(pointer) }
    return String(cString: pointer)
}

/// Run an async operation to completion from a synchronous CLI handler.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Result<T, Error>!
    Task {
        do { outcome = await .success(try operation()) } catch { outcome = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try outcome.get()
}

/// A finished turn exits 0 — whatever the stop reason, `refusal` included — unless
/// it needed permission and was granted none: then `PERMISSION_DENIED` (5), even
/// though the agent completed. acpx's `applyPermissionExitCode`; quiet mode also
/// says why on stderr, since it prints nothing else.
///
/// A write that needed an answer nobody could give (`--non-interactive-permissions
/// fail`) fails the run outright: upstream rethrows it after the turn, so it wins
/// over any approval, and quiet mode names it as `PERMISSION_PROMPT_UNAVAILABLE`.
/// On a persistent session that error comes back through acpx's queue, which adds
/// the `QUEUE_RUNTIME_PROMPT_FAILED` detail code — pass it as `queueDetail`.
func permissionExitCode(_ stats: PermissionStats, quiet: Bool, queueDetail: String? = nil) -> Int32 {
    if stats.promptUnavailable {
        if quiet {
            let detail = queueDetail.map { "\($0) " } ?? ""
            Console.errLine(
                "[acpx] error: PERMISSION_PROMPT_UNAVAILABLE \(detail)"
                    + FileSystemPermissionError.promptUnavailable.description)
        }
        return ExitCodes.permissionDenied
    }
    guard stats.deniedEverything else { return ExitCodes.success }
    if quiet { Console.errLine("[acpx] error: PERMISSION_DENIED Permission request denied or cancelled") }
    return ExitCodes.permissionDenied
}
