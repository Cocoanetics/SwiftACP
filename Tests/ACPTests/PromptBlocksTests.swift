@testable import ACPXCore
@testable import acpxd
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// Prompt content blocks on `runPrompt`: what reaches the agent on the wire, what
/// the daemon refuses before it gets there, and what lands in the persisted record.
///
/// Serialized for the same reason as ``DaemonToolsTests`` — these redirect the
/// process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct PromptBlocksTests {
    /// A 2×2 red PNG — small, but a real one, so `Data(base64Encoded:)` and the mock
    /// agent's own decode both have something valid to chew on.
    static let pngBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP8zwACTGCSAQANHQEDgslx/wAAAABJRU5ErkJggg==
        """
    static var png: PromptBlock { .image(mimeType: "image/png", data: pngBase64) }

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
                sessionId: id, text: "what is this?", blocks: [Self.png])

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

            _ = try await daemon.runPrompt(sessionId: id, text: "", blocks: [Self.png])

            let blocks = try promptBlocks(log)
            #expect(blocks.count == 1)
            #expect(blocks.first?["type"] as? String == "image")
        }
    }

    // MARK: - What the daemon refuses

    /// The mock advertises `promptCapabilities.image: false` unless told otherwise,
    /// so this is the capability gate, checked once the agent is connected — as acpx
    /// checks it when it prompts.
    @Test(.enabled(if: mockPythonAvailable))
    func imagesAreRefusedWhenTheAgentDoesNotAdvertiseThem() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: command, cwd: NSTemporaryDirectory())

            let refusal = await #expect(throws: UnsupportedPromptContentError.self) {
                _ = try await daemon.runPrompt(
                    sessionId: id, text: "look", blocks: [Self.png])
            }
            #expect(refusal?.index == 1)
            #expect(refusal?.capability == "image")

            // acpx records the prompt before it connects, so the refused turn is in the
            // history although the agent never saw it — and nothing answered it.
            let history = try await daemon.sessionHistory(sessionId: id)
            #expect(history.map(\.role) == ["user"])
            #expect(history.first?.textPreview.contains("look") == true)
        }
    }

    /// A PDF is the case from the field: both shipped adapters mishandle an embedded
    /// blob (one drops it, one inlines its base64 as text), so an image block refuses
    /// it and points the caller at the path that does work.
    @Test func nonImageTypesAreRefusedWithGuidance() throws {
        let bad = PromptBlock.image(mimeType: "application/pdf", data: Self.pngBase64)
        #expect(throws: PromptBlockError.unsupportedImageMimeType(
            index: 0, mimeType: "application/pdf")) {
            _ = try blocks("read this", bad)
        }
        let message = PromptBlockError
            .unsupportedImageMimeType(index: 0, mimeType: "application/pdf")
            .errorDescription ?? ""
        #expect(message.contains("send a resource_link"))
    }

    /// The same guidance for the other way a caller reaches for a binary: an embedded
    /// resource with no text. There is no `blob` field to fill in the first place.
    @Test func embeddedResourcesWithoutTextAreRefused() {
        #expect(throws: PromptBlockError.binaryResource(index: 0)) {
            _ = try blocks("read this", PromptBlock(type: "resource", uri: "file:///tmp/a.pdf"))
        }
        #expect(throws: Never.self) {
            _ = try blocks(
                "read this",
                PromptBlock(type: "resource", text: "hello", uri: "file:///tmp/a.txt"))
        }
    }

    @Test func unknownBlockTypesAndMissingFieldsAreRefused() {
        #expect(throws: PromptBlockError.unsupportedBlockType(index: 0, type: "video")) {
            _ = try blocks("hi", PromptBlock(type: "video"))
        }
        #expect(throws: PromptBlockError.missingField(index: 0, type: "text", field: "text")) {
            _ = try blocks("hi", PromptBlock(type: "text"))
        }
        #expect(throws: PromptBlockError.missingField(index: 0, type: "resource_link", field: "uri")) {
            _ = try blocks("hi", PromptBlock(type: "resource_link", name: "a.txt"))
        }
    }

    /// `resource_link` is the file path, and the common case — a bare URI — should
    /// not need a name spelled out, so it falls back to the URI's last component.
    @Test func resourceLinksNameThemselvesFromTheirURI() throws {
        let content = try blocks("read this", .resourceLink(uri: "file:///tmp/spec.pdf"))
        guard case .resourceLink(let link) = content.last else {
            Issue.record("expected a resource_link block")
            return
        }
        #expect(link.uri == "file:///tmp/spec.pdf")
        #expect(link.name == "spec.pdf")
    }

    @Test func malformedBase64IsRefused() {
        // Present but not decodable, including the padding-less and wrapped forms the
        // adapters would pass straight through to the model.
        for data in ["not base64!", "iVBORw0KGgo", "iVBO Rw0K"] {
            #expect(throws: PromptBlockError.invalidBase64(index: 0), "\(data)") {
                _ = try blocks("hi", .image(mimeType: "image/png", data: data))
            }
        }
        // Absent entirely reads as the missing field it is, not as bad base64.
        #expect(throws: PromptBlockError.missingField(index: 0, type: "image", field: "data")) {
            _ = try blocks("hi", .image(mimeType: "image/png", data: ""))
        }
    }

    /// The cap is on the turn's total, not on any single block.
    @Test func oversizedBlocksAreRefusedInAggregate() throws {
        // Each a little over half the budget: one fits, the pair does not.
        let encoded = PromptBlock.maxRequestBytes / 2 + 16 * 1024
        let half = PromptBlock.image(
            mimeType: "image/png",
            data: Data(repeating: 0x41, count: encoded / 4 * 3).base64EncodedString())
        #expect(throws: Never.self) { _ = try blocks("one", half) }
        #expect(throws: PromptBlockError.self) { _ = try blocks("two", half, half) }
    }

    /// The budget is spent on the *encoded* request, not on the bytes it decodes to.
    /// An image decoding to 3 MiB is exactly 4 MiB of base64 — the whole transport
    /// ceiling, with nothing left for the prompt and envelope around it — so it has
    /// to be refused even though its decoded size sounds modest.
    @Test func aBlockFillingTheTransportBudgetIsRefused() {
        let image = PromptBlock.image(
            mimeType: "image/png",
            data: Data(repeating: 0x41, count: PromptBlock.maxRequestBytes / 4 * 3)
                .base64EncodedString())
        #expect(throws: PromptBlockError.self) { _ = try blocks("hi", image) }
    }

    /// Prompt text shares the budget with the blocks.
    @Test func longPromptTextCountsAgainstTheBudget() throws {
        let image = PromptBlock.image(
            mimeType: "image/png",
            data: Data(repeating: 0x41, count: PromptBlock.maxRequestBytes / 2)
                .base64EncodedString())
        #expect(throws: Never.self) { _ = try blocks("short", image) }
        #expect(throws: PromptBlockError.self) {
            _ = try blocks(String(repeating: "x", count: PromptBlock.maxRequestBytes / 2), image)
        }
    }

    /// A caller talking to an agent directly has no transport in the way, so the cap
    /// is the daemon's to apply, not the conversion's.
    @Test func withoutARequestLimitSizeIsNotChecked() {
        let huge = PromptBlock.image(
            mimeType: "image/png",
            data: Data(repeating: 0x41, count: PromptBlock.maxRequestBytes)
                .base64EncodedString())
        #expect(throws: Never.self) {
            _ = try PromptBlock.contentBlocks(text: "hi", blocks: [huge], requestLimit: nil)
        }
    }

    @Test func aTurnWithNeitherTextNorBlocksIsRefused() {
        #expect(throws: PromptBlockError.emptyPrompt) {
            _ = try PromptBlock.contentBlocks(text: "", blocks: nil, requestLimit: nil)
        }
        #expect(throws: PromptBlockError.emptyPrompt) {
            _ = try PromptBlock.contentBlocks(text: "", blocks: [], requestLimit: nil)
        }
    }

    // MARK: - What gets persisted

    /// The record keeps the image as acpx 0.19.3 records it, its data and MIME type
    /// (openclaw/acpx#766, #88), and the history names it by its type, not its data.
    @Test(.enabled(if: mockPythonAvailable))
    func persistedTurnKeepsTheImageAsAcpxRecordsIt() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: imageCapable(command, log: requestLog()),
                cwd: NSTemporaryDirectory())

            _ = try await daemon.runPrompt(
                sessionId: id, text: "what is this?", blocks: [Self.png])

            let history = try await daemon.sessionHistory(sessionId: id)
            let user = try #require(history.first)
            #expect(user.role == "user")
            #expect(user.textPreview == "what is this? [image] image/png")

            let file = try #require(WireJSON(parsing: Data(contentsOf: ACPXPaths.sessionRecordPath(id))))
            guard case .array(let messages)? = file["messages"],
                  case .array(let content)? = messages.first?["User"]?["content"], content.count == 2
            else {
                Issue.record("expected a user message of text and an image: \(file.stringified)")
                return
            }
            #expect(content[1].stringified
                == #"{"Image":{"source":"\#(Self.pngBase64)","mime_type":"image/png","size":null}}"#)
        }
    }

    /// acpx 0.19.3's `userContentToText`: an image or an audio clip by its type, never
    /// its data, however the record came by it; no type, or an empty one, as the kind.
    @Test func aHistoryPreviewNamesAnImageByItsType() {
        func image(_ mimeType: Nullable<String>?) -> SessionUserContent {
            .image(SessionMessageImage(source: Self.pngBase64, mimeType: mimeType, size: .null))
        }
        #expect(image(.value("image/png")).previewText == "[image] image/png")
        #expect(image(nil).previewText == "[image] image")
        #expect(image(.null).previewText == "[image] image")
        #expect(image(.value("")).previewText == "[image] image")
        #expect(SessionUserContent.audio(SessionMessageAudio(source: "UklGRg==", mimeType: "audio/wav")).previewText
            == "[audio] audio/wav")
        #expect(SessionUserContent.audio(SessionMessageAudio(source: "UklGRg==", mimeType: "")).previewText
            == "[audio] audio")
    }

    // MARK: - Content as written (#103)

    /// `content` is checked by acpx's rules rather than `blocks`' — an `image/bmp`, which
    /// `blocks` refuses, goes through — and reaches the agent as written: a `null` title
    /// and a block's `_meta` included.
    @Test(.enabled(if: mockPythonAvailable))
    func contentReachesTheAgentAsWrittenUnderAcpxsRules() async throws {
        let command = try #require(mockCommand())
        try await withIsolatedStore {
            let log = requestLog()
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let id = try await daemon.newSession(
                agentCommand: imageCapable(command, log: log), cwd: NSTemporaryDirectory())
            _ = try await daemon.runPrompt(sessionId: id, text: "", content: [
                .object(["type": .string("image"), "mimeType": .string("image/bmp"), "data": .string(Self.pngBase64)]),
                .object([
                    "type": .string("resource_link"), "uri": .string("file:///tmp/a.pdf"), "name": .string("a.pdf"),
                    "title": .null, "_meta": .object(["k": .integer(1)])
                ]),
                .object(["type": .string("text"), "text": .string("t"), "_meta": .null, "x-custom": .bool(true)])
            ])
            let blocks = try promptBlocks(log)
            #expect(blocks.first?["mimeType"] as? String == "image/bmp")
            #expect(blocks[1]["title"] is NSNull)
            #expect((blocks[1]["_meta"] as? [String: Any])?["k"] as? Int == 1)
            // What a block's type does not hold goes on too (#114 review).
            #expect(blocks.last?["_meta"] is NSNull)
            #expect(blocks.last?["x-custom"] as? Bool == true)
        }
    }

    /// A block acpx does not take is refused in its words before the turn is queued, and
    /// so is a turn that sends both kinds of block.
    @Test func contentAcpxDoesNotTakeIsRefusedInItsWords() async throws {
        try await withIsolatedStore {
            let daemon = ACPXDaemonBackend(inheritAgentStderr: false)
            let video: JSONValue = .object(["type": .string("video")])
            let refused = await #expect(throws: PromptContent.ValidationError.self) {
                _ = try await daemon.runPrompt(sessionId: "any", text: "", content: [video])
            }
            #expect(refused?.message == #"prompt[0] has unsupported content block type "video""#)
            await #expect(throws: PromptContent.ValidationError.self) {
                _ = try await daemon.runPrompt(sessionId: "any", text: "", blocks: [.text("x")], content: [video])
            }
        }
    }

    // MARK: - Helpers

    /// Convert with the daemon's transport cap applied — what a `runPrompt` turn does.
    private func blocks(_ text: String, _ blocks: PromptBlock...) throws -> [ContentBlock] {
        try PromptBlock.contentBlocks(
            text: text, blocks: blocks, requestLimit: PromptBlock.maxRequestBytes)
    }

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
