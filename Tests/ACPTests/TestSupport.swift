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

/// Serializes ``withIsolatedStore`` bodies across the whole process. swift-testing
/// runs different suites in parallel, but every store / daemon-lock test redirects
/// the single process-wide ``ACPXPaths/baseDir``; without this gate two suites would
/// interleave their redirects and point one suite's files at another's temp dir.
private actor StoreIsolationGate {
    static let shared = StoreIsolationGate()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Run `body` with ``ACPXPaths/baseDir`` pointed at a fresh temp directory, so
/// persistence never touches the real `~/.acpx`. Restores it afterwards, and
/// serializes against every other `withIsolatedStore` call process-wide.
func withIsolatedStore<T>(_ body: () async throws -> T) async rethrows -> T {
    await StoreIsolationGate.shared.lock()
    defer { Task { await StoreIsolationGate.shared.unlock() } }
    let original = ACPXPaths.baseDir
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("acpx-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    ACPXPaths.baseDir = dir
    defer {
        ACPXPaths.baseDir = original
        try? FileManager.default.removeItem(at: dir)
    }
    return try await body()
}
