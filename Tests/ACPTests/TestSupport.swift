@testable import ACPXCore
import Foundation
import SwiftACP

/// Whether `python3` is available for the bundled `mock-agent.py` fixture. Gates
/// the tests that spawn the mock agent.
let mockPythonAvailable = AgentRegistry.which("python3") != nil

/// `agentCommand` for the mock: an unknown name with no override is treated as a
/// literal command line by `AgentRegistry`, so a bare `python3 <script>` launches
/// the bundled fixture. Returns nil if python3 / the fixture isn't available.
func mockCommand() -> String? {
    guard let python = AgentRegistry.which("python3") else { return nil }
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mock-agent.py")
    guard FileManager.default.fileExists(atPath: fixture.path) else { return nil }
    return "'\(python)' '\(fixture.path)'"
}

/// The mock agent as an argv — interpreter and script — for launches that are not
/// split from a command line.
func mockArgv() -> [String]? {
    guard let python = AgentRegistry.which("python3") else { return nil }
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mock-agent.py")
    guard FileManager.default.fileExists(atPath: fixture.path) else { return nil }
    return [python, fixture.path]
}

/// From the first isolated store on, a read of the store outside every test's own finds a
/// directory that cannot exist rather than the real `~/.acpx`: nothing is there, and
/// nothing can be written there.
private let unboundStoreFails: Void = {
    ACPXPaths.processBaseDir = URL(fileURLWithPath: "/dev/null/no-isolated-store", isDirectory: true)
}()

/// Run `body` with a fresh temp directory as its task's ``ACPXPaths/baseDir``, so
/// persistence never touches the real `~/.acpx`, and tests with stores of their own run
/// side by side. A thread `body` starts is in the store only if given it
/// (``onThreadOfItsOwn(_:)``).
func withIsolatedStore<T>(_ body: () async throws -> T) async rethrows -> T {
    _ = unboundStoreFails
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("acpx-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A turn waits a second past the agent's answer, as acpx's does; the tests have no
    // late updates to wait for, but those that do say so.
    return try await ACPXPaths.$taskBaseDir.withValue(dir) {
        try await TurnReplyDrain.$current.withValue(.forTests) { try await body() }
    }
}

/// `body` on a thread of its own, in the calling test's store: a thread starts with none
/// of its task's locals. The CLI blocks its thread until it is done (`runBlocking`); on
/// one of the tasks' own threads, enough tests doing that at once would leave none to run
/// the tasks they wait for.
func onThreadOfItsOwn<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    let store = ACPXPaths.taskBaseDir
    return await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: ACPXPaths.$taskBaseDir.withValue(store) { body() }) }.start()
    }
}

extension ReplyDrain {
    /// A wait short enough not to hold up every daemon test by a second.
    static let forTests = ReplyDrain(idleMilliseconds: 20, timeoutMilliseconds: 1_000)
}
