@testable import ACPXCore
@testable import acpx
@testable import acpxd
import Foundation
import SwiftACP
import SwiftMCP
import Testing

/// How a session's line takes a prompt, as acpx's queue owner takes one (`enqueue`): past the
/// owner's depth it is refused (#240), and one queued without waiting — acpx's `--no-wait` —
/// is over for its caller once the line has it, and runs on telling no one (#239).
extension DaemonToolsTests {
    /// A prompt that would wait behind as many as the depth allows is refused, in acpx's words:
    /// the depth the line began with until the session has an owner, then the owner's — never
    /// the one the prompt itself brings, as acpx's owner keeps the depth it was spawned with.
    @Test func aPromptPastTheQueueDepthIsRefused() async throws {
        // Bounded, so that a line that never moves fails rather than hangs.
        try await withTimeout(milliseconds: 10_000) {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let (waits, waiting) = AsyncStream<Void>.makeStream()
            await daemon.setPromptWaits { _ in waiting.yield() }
            let first = try await daemon.beginPrompt("s", queueMaxDepth: 1)
            let second = Task { try await daemon.beginPrompt("s", queueMaxDepth: 5) }
            try await nextEvent(waits)
            await #expect(throws: QueueOwnerOverloaded(queued: 1, depth: 1)) {
                try await daemon.beginPrompt("s", queueMaxDepth: 5)
            }
            #expect(QueueOwnerOverloaded(queued: 1, depth: 1).localizedDescription
                == "Queue owner is overloaded (1/1 queued)")

            // Once the session has an owner, its depth — 16, here — is the one.
            await daemon.holdAsAnOwner("s", ttlMilliseconds: 60_000)
            let third = Task { try await daemon.beginPrompt("s", queueMaxDepth: 1) }
            try await nextEvent(waits)

            #expect(await daemon.endPromptAndLook("s", first) != nil)
            let secondBegun = try await second.value
            #expect(await daemon.endPromptAndLook("s", secondBegun) != nil)
            let thirdBegun = try await third.value
            #expect(await daemon.endPromptAndLook("s", thirdBegun) == nil)
            await daemon.forgetOwner("s")
        }
    }

    /// The depth an owner is started with is its first prompt's, at least 1, and 16 when that
    /// prompt brings none, as acpx normalizes its owner's (`Math.max(1, …)`).
    @Test func anOwnersDepthIsItsFirstPromptsAtLeastOne() async throws {
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        for (brought, kept) in [(Int?.none, 16), (3, 3), (0, 1), (-2, 1)] {
            await daemon.turnStarts("s", ttlMs: nil, queueMaxDepth: brought)
            #expect(await daemon.owners["s"]?.maxQueueDepth == kept, "\(String(describing: brought))")
            await daemon.turnStarts("s", ttlMs: nil, queueMaxDepth: 9)
            #expect(await daemon.owners["s"]?.maxQueueDepth == kept, "a running owner keeps its own")
            await daemon.forgetOwner("s")
        }
    }

    /// A prompt queued without waiting is over for its caller as soon as the line has it — here
    /// behind a prompt begun — and runs once its turn comes, as any queued prompt; one past the
    /// depth is refused, the call failing as a refusal fails a prompt that waits.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func aPromptQueuedWithoutWaitingIsOverOnceTheLineHasIt() async throws {
        let agent = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(agentCommand: agent, cwd: NSTemporaryDirectory())
            let first = try await daemon.beginPrompt(id, queueMaxDepth: 1)
            #expect(try await daemon.runPrompt(sessionId: id, text: "queued", wait: false) == "")
            #expect(await daemon.promptsWaiting(id) == 1)
            await #expect(throws: QueueOwnerOverloaded(queued: 1, depth: 1)) {
                try await daemon.runPrompt(sessionId: id, text: "refused", wait: false)
            }

            await daemon.promptEnded(id, first, heldTheSlot: false).value
            // A prompt that waits comes after it: once that is over, so is the queued one.
            _ = try await daemon.runPrompt(sessionId: id, text: "after")
            let asked = try await daemon.sessionHistory(sessionId: id).filter { $0.role == "user" }
            #expect(asked.map(\.textPreview) == ["queued", "after"])
            await daemon.releaseAll()
        }
    }

    /// `--no-wait` prints acpx's queued result — `[queued] <requestId>`, `prompt_queued` in JSON,
    /// nothing when quiet — once the session's owner has the prompt, here behind a turn the agent
    /// holds, and exits 0; each is recorded as it runs on. Under `--verbose`, the owner's line
    /// comes first, as acpx writes it once the owner answers `accepted`.
    @Test(.enabled(if: mockPythonAvailable), .timeLimit(.minutes(1)))
    func noWaitPrintsAcpxsQueuedResult() async throws {
        let agent = "/usr/bin/env MOCK_LOAD_SESSION=ok " + (try #require(mockCommand()))
        let directory = try DaemonToolsTests.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withIsolatedStore {
            let backend = ACPXDaemonBackend(inheritAgentStderr: false)
            let daemon = MCPServerConfig.stdioHandles(server: ACPXDaemon(backend: backend))
            // Bounded, and not by cancellation, which a command blocked on its thread never sees: one
            // that would wait fails the test rather than hang the run.
            @Sendable func acpx(_ args: [String]) async throws -> OwnerLinesTests.Run {
                try await withTimeout(milliseconds: 20_000) {
                    let capture = Console.Capture()
                    let code: Int32 = await onThreadOfItsOwn {
                        DaemonClient.$standIn.withValue(daemon) {
                            Console.$capture.withValue(capture) {
                                runCommandLine(["--approve-all", "--agent", agent, "--cwd", directory.path] + args)
                            }
                        }
                    }
                    return OwnerLinesTests.Run(code: code, out: capture.out, err: capture.err, merged: capture.merged)
                }
            }
            let id = try await acpx(["--format", "quiet", "sessions", "new"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = ProcessInfo.processInfo.processIdentifier
            // A turn the agent holds until it is cancelled has the session first.
            let (goes, goingOut) = AsyncStream<Void>.makeStream()
            await backend.setPromptGoingOut { _ in goingOut.yield() }
            let held = Task { try await acpx(["--format", "quiet", "prompt", "hold turn"]) }
            try await nextEvent(goes)

            let text = try await acpx(["--verbose", "prompt", "--no-wait", "first"])
            #expect(text.code == 0)
            #expect(Self.isQueued(text.out, prefix: "[queued] ", suffix: "\n"))
            let line = "[acpx] queued prompt on active owner pid \(pid) for session \(id)\n"
            #expect(text.merged.contains(line + "[queued] "))
            let json = try await acpx(["--format", "json", "prompt", "--no-wait", "second"])
            #expect(json.code == 0)
            let prefix = #"{"action":"prompt_queued","acpxRecordId":"\#(id)","requestId":""#
            #expect(Self.isQueued(json.out, prefix: prefix, suffix: "\"}\n"))
            let quiet = try await acpx(["--format", "quiet", "prompt", "--no-wait", "third"])
            #expect(quiet.code == 0)
            #expect(quiet.out.isEmpty)

            #expect(try await acpx(["cancel"]).code == 0)
            _ = try await held.value
            // A prompt that waits comes after them: once it is over, so are they.
            #expect(try await acpx(["--format", "quiet", "prompt", "after"]).code == 0)
            let asked = try await backend.sessionHistory(sessionId: id).filter { $0.role == "user" }
            #expect(asked.map(\.textPreview) == ["hold turn", "first", "second", "third", "after"])
            // Each turn's journal records are keyed by the id its CLI printed, as acpx's owner keys
            // them by the request id its CLI sent.
            let journal = try String(contentsOf: ACPXPaths.sessionStreamPath(id), encoding: .utf8)
            let printed = [text.out, json.out].compactMap(Self.requestId(in:))
            #expect(printed.count == 2)
            for requestId in printed {
                #expect(journal.contains(#""type":"turn_started","request_id":"\#(requestId)""#))
            }
            await backend.releaseAll()
        }
    }

    /// The lowercase UUID in `output`.
    static func requestId(in output: String) -> String? {
        output.range(of: "[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", options: .regularExpression)
            .map { String(output[$0]) }
    }

    /// Whether `output` is `prefix`, a lowercase UUID, then `suffix`.
    static func isQueued(_ output: String, prefix: String, suffix: String) -> Bool {
        guard output.hasPrefix(prefix), output.hasSuffix(suffix) else { return false }
        let requestId = output.dropFirst(prefix.count).dropLast(suffix.count)
        return UUID(uuidString: String(requestId)) != nil && requestId == requestId.lowercased()
    }
}

extension ACPXDaemonBackend {
    /// How many prompts wait in `recordId`'s line.
    func promptsWaiting(_ recordId: String) -> Int {
        promptLines[recordId]?.waiting.count ?? 0
    }
}
