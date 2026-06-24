import Foundation
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
struct UsageError: Error {
    var message: String
    init(_ message: String) { self.message = message }
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

/// Build a `JSONValue` object from ordered pairs (the encoder sorts keys, so the
/// pair order is for readability only).
func jsonObject(_ pairs: [(String, JSONValue)]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: pairs))
}

extension JSONValue {
    /// Compact single-line JSON (sorted keys, unescaped slashes) for `--format json`.
    func compact() -> String { jsonString(self) }

    /// 2-space pretty JSON (sorted keys) for human-facing output (e.g. `config show`).
    func pretty() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
}

/// Write a JSON result envelope to stdout when the format is json.
@discardableResult
func emitJsonResult<E: Encodable>(_ format: String, _ value: E) -> Bool {
    guard format == "json" else { return false }
    Console.out(jsonString(value) + "\n")
    return true
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
