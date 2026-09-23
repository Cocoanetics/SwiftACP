@testable import ACPXCore
@testable import acpxd
import Foundation
import SwiftACP
import Testing

/// Image attachments on `runPrompt`: what reaches the agent on the wire, what the
/// daemon refuses before it gets there, and what lands in the persisted record.
///
/// Serialized for the same reason as ``DaemonToolsTests`` — these redirect the
/// process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct PromptAttachmentsTests {
    /// A 2×2 red PNG — small, but a real one, so `Data(base64Encoded:)` and the mock
    /// agent's own decode both have something valid to chew on.
    static let pngBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP8zwACTGCSAQANHQEDgslx/wAAAABJRU5ErkJggg==
        """
    static var png: PromptAttachment { PromptAttachment(mimeType: "image/png", data: pngBase64) }

    // MARK: - What reaches the agent

    @Test(.enabled(if: mockPythonAvailable))
    func imageAttachmentReachesTheAgentAsAnImageBlock() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLog()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: imageCapable(command, log: log), cwd: NSTemporaryDirectory())

            let reply = try await daemon.runPrompt(
                sessionId: id, text: "what is this?", attachments: [Self.png])

            // The mock decodes the base64 itself and reports the byte count, so a
            // reply naming it proves the payload survived the round trip intact.
            #expect(reply.contains("[image image/png 73 bytes]"))

            // Text block first, then the image — npm acpx's `toPromptInput` order.
            let blocks = try promptBlocks(log)
            #expect(blocks.count == 2)
            #expect(blocks.first?["type"] as? String == "text")
            #expect(blocks.first?["text"] as? String == "what is this?")
            #expect(blocks.last?["type"] as? String == "image")
            #expect(blocks.last?["mimeType"] as? String == "image/png")
            #expect(blocks.last?["data"] as? String == Self.pngBase64)
        }
    }

    /// Empty text contributes no block, so an image can carry a turn by itself.
    @Test(.enabled(if: mockPythonAvailable))
    func imageOnlyTurnSendsNoTextBlock() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLog()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: imageCapable(command, log: log), cwd: NSTemporaryDirectory())

            _ = try await daemon.runPrompt(sessionId: id, text: "", attachments: [Self.png])

            let blocks = try promptBlocks(log)
            #expect(blocks.count == 1)
            #expect(blocks.first?["type"] as? String == "image")
        }
    }

    // MARK: - What the daemon refuses

    /// The mock advertises `promptCapabilities.image: false` unless told otherwise,
    /// so this is the capability gate, checked once the agent is connected.
    @Test(.enabled(if: mockPythonAvailable))
    func imagesAreRefusedWhenTheAgentDoesNotAdvertiseThem() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory())

            await #expect(throws: PromptAttachmentError.self) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "look", attachments: [Self.png])
            }

            // The gate runs before the prompt is recorded, so a turn the agent never
            // saw leaves no user message behind — however slowly the agent launched.
            #expect(try await daemon.sessionHistory(sessionId: id).isEmpty)
        }
    }

    /// A PDF is the case from the field: both shipped adapters mishandle an embedded
    /// blob (one drops it, one inlines its base64 as text), so we refuse it here and
    /// point the caller at the path that does work.
    @Test func nonImageAttachmentsAreRefusedWithGuidance() throws {
        #expect(throws: PromptAttachmentError.unsupportedMimeType(index: 0, mimeType: "application/pdf")) {
            _ = try PromptAttachment.promptBlocks(
                text: "read this",
                attachments: [PromptAttachment(mimeType: "application/pdf", data: Self.pngBase64)])
        }
        let message = PromptAttachmentError
            .unsupportedMimeType(index: 0, mimeType: "application/pdf").errorDescription ?? ""
        #expect(message.contains("images only"))
        #expect(message.contains("name its path in the prompt text"))
    }

    @Test func malformedBase64IsRefused() {
        for data in ["", "not base64!", "iVBORw0KGgo"] {
            #expect(throws: PromptAttachmentError.invalidBase64(index: 0)) {
                _ = try PromptAttachment.promptBlocks(
                    text: "hi", attachments: [PromptAttachment(mimeType: "image/png", data: data)])
            }
        }
    }

    /// The cap is on the turn's total, not on any single attachment.
    @Test func oversizedAttachmentsAreRefusedInAggregate() throws {
        let half = PromptAttachment(
            mimeType: "image/png",
            data: Data(repeating: 0x41, count: PromptAttachment.maxTotalBytes / 2 + 1)
                .base64EncodedString())
        #expect(throws: Never.self) {
            _ = try PromptAttachment.promptBlocks(text: "one", attachments: [half])
        }
        #expect(throws: PromptAttachmentError.self) {
            _ = try PromptAttachment.promptBlocks(text: "two", attachments: [half, half])
        }
    }

    @Test func aTurnWithNeitherTextNorAttachmentsIsRefused() {
        #expect(throws: PromptAttachmentError.emptyPrompt) {
            _ = try PromptAttachment.promptBlocks(text: "", attachments: nil)
        }
        #expect(throws: PromptAttachmentError.emptyPrompt) {
            _ = try PromptAttachment.promptBlocks(text: "", attachments: [])
        }
    }

    /// Validation runs before the record lookup, so a caller learns their attachment
    /// is bad even when the session id is also wrong.
    @Test func attachmentsAreValidatedBeforeTheSessionIsResolved() async throws {
        let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
        await #expect(throws: PromptAttachmentError.self) {
            _ = try await daemon.runPrompt(
                sessionId: "does-not-exist", text: "hi",
                attachments: [PromptAttachment(mimeType: "image/tiff", data: Self.pngBase64)])
        }
    }

    // MARK: - What gets persisted

    /// The record keeps the MIME type and drops the payload: acpx writes the whole
    /// base64 into the session file and then prints it as the history preview.
    @Test(.enabled(if: mockPythonAvailable))
    func persistedTurnKeepsTheMimeTypeButNotTheBase64() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: imageCapable(command, log: requestLog()),
                cwd: NSTemporaryDirectory())

            _ = try await daemon.runPrompt(
                sessionId: id, text: "what is this?", attachments: [Self.png])

            let history = try await daemon.sessionHistory(sessionId: id)
            let user = try #require(history.first)
            #expect(user.role == "user")
            #expect(user.textPreview.contains("what is this?"))
            #expect(user.textPreview.contains("[image] image/png"))

            let record = try #require(SessionStore.loadRecord(id))
            guard case .user(let message) = try #require(record.messages.first) else {
                Issue.record("first message is not a user message")
                return
            }
            #expect(message.content.count == 2)
            guard case .image(let image) = message.content.last else {
                Issue.record("second content block is not an image")
                return
            }
            #expect(image.mimeType == "image/png")
            #expect(image.source.isEmpty)

            // Belt and braces: the base64 is nowhere in the file on disk.
            let json = try String(
                contentsOf: ACPXPaths.sessionRecordPath(id), encoding: .utf8)
            #expect(!json.contains(Self.pngBase64))
        }
    }

    // MARK: - Helpers

    private func requestLog() -> URL {
        ACPXPaths.baseDir.appendingPathComponent("requests-\(UUID().uuidString).ndjson")
    }

    /// The mock agent, with image prompt capability switched on and every `session/*`
    /// request it receives appended to `log`.
    private func imageCapable(_ command: String, log: URL) -> String {
        "/usr/bin/env MOCK_IMAGE_CAPABLE=1 MOCK_REQUEST_LOG='\(log.path)' \(command)"
    }

    /// The content blocks of the one `session/prompt` request the agent received.
    private func promptBlocks(_ log: URL) throws -> [[String: Any]] {
        let requests = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let request = try #require(requests.first { $0["method"] as? String == "session/prompt" })
        let params = try #require(request["params"] as? [String: Any])
        return try #require(params["prompt"] as? [[String: Any]])
    }
}
