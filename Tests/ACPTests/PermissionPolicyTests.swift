@testable import ACPXCore
@testable import acpx
import Foundation
import JSONFoundation
import SwiftACP
import Testing

/// `--permission-policy` / `--policy` as acpx reads and shows it (#97): inline JSON or a
/// file, refused with acpx's words as a usage error, and an escalation printed as a
/// `[permission]` notice with its details. Lines are acpx 0.19.1's.
@Suite struct PermissionPolicyTests {
    private enum Loaded: Equatable {
        case success(PermissionRules?)
        case failure(String)
    }

    private static func load(_ spec: String?, cwd: String = "/work") -> Loaded {
        do {
            return .success(try PermissionRulesLoader.load(spec, cwd: cwd))
        } catch let invalid as PermissionRulesLoader.Invalid {
            return .failure(invalid.message)
        } catch {
            return .failure("\(error)")
        }
    }

    @Test func inlineJSONIsRead() {
        #expect(Self.load(#"  {"autoApprove":[" read "],"escalate":["execute"],"defaultAction":"deny"} "#)
            == .success(PermissionRules(autoApprove: ["read"], escalate: ["execute"], defaultAction: .deny)))
        #expect(Self.load(#"{"autoApprove": null}"#) == .success(PermissionRules()))
        #expect(Self.load("  ") == .success(nil))
        #expect(Self.load(nil) == .success(nil))
    }

    @Test func aPolicyThatDoesNotReadIsRefusedInAcpxsWords() {
        #expect(Self.load(#"{"autoApprove": "edit"}"#)
            == .failure("--permission-policy: permission policy autoApprove must be an array of strings"))
        #expect(Self.load(#"{"autoDeny": ["", "x"]}"#)
            == .failure("--permission-policy: permission policy autoDeny must contain only non-empty strings"))
        #expect(Self.load(#"{"defaultAction": "maybe"}"#)
            == .failure("--permission-policy: permission policy defaultAction must be one of approve, deny, escalate"))
        #expect(Self.load("{bad json")
            == .failure("Expected property name or '}' in JSON at position 1 (line 1 column 2)"))
        // Not `{`: a file, relative to the working directory.
        #expect(Self.load("[1]") == .failure("ENOENT: no such file or directory, open '/work/[1]'"))
    }

    @Test func aFileIsReadRelativeToTheWorkingDirectory() throws {
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("policy-\(UUID().uuidString)").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try #"{"escalate":["edit"]}"#.write(toFile: cwd + "/policy.json", atomically: true, encoding: .utf8)
        try #"[1]"#.write(toFile: cwd + "/list.json", atomically: true, encoding: .utf8)
        #expect(Self.load("policy.json", cwd: cwd) == .success(PermissionRules(escalate: ["edit"])))
        #expect(Self.load("list.json", cwd: cwd)
            == .failure("\(cwd)/list.json: permission policy must be a JSON object"))
    }

    // MARK: The escalation, shown

    static let escalation: PermissionEscalation = {
        var toolCall = ToolCallUpdate(toolCallId: "t1", title: "Edit notes.txt", kind: .edit)
        toolCall.rawInput = .object(["path": .string("notes.txt")])
        return PermissionEscalation(
            RequestPermissionRequest(sessionId: "s-1", toolCall: toolCall, options: []),
            matchedRule: "edit", timestamp: "2026-09-24T00:00:00.000Z")
    }()

    static let operation = ClientOperation(
        method: ClientOperation.requestPermission, status: .completed, summary: escalation.message,
        timestamp: "2026-09-24T00:00:00.000Z", sessionId: "s-1", escalation: escalation)

    @Test func textOutputShowsTheEscalationWithItsDetails() {
        let (out, err) = OutputRendererTests.capture(.text) { $0.clientOperation(Self.operation) }
        #expect(out == """
            [permission] Permission escalation required for Edit notes.txt
              sessionId: s-1
              toolCallId: t1
              toolName: Edit
              toolTitle: Edit notes.txt
              toolInput: notes.txt
              toolKind: edit
              matchedRule: edit

            """)
        #expect(err.isEmpty)
    }

    /// acpx's quiet formatter prints nothing for it.
    @Test func quietOutputShowsNothing() {
        let (out, err) = OutputRendererTests.capture(.quiet) { $0.clientOperation(Self.operation) }
        #expect(out.isEmpty && err.isEmpty)
    }

    // MARK: End to end

    private struct Ran {
        var code: Int32
        var out: String
        var err: String
    }

    private static func exec(_ flags: [String], environment: String = "MOCK_TOOL_PERMISSION=1") async throws -> Ran {
        let python = try #require(AgentRegistry.which("python3"))
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/write-agent.py")
        let command = "/usr/bin/env \(environment) '\(python)' '\(fixture.path)'"
        return try await withIsolatedStore {
            let capture = Console.Capture()
            let code = Console.$capture.withValue(capture) {
                runCommandLine(flags + ["--agent", command, "exec", "go"])
            }
            return Ran(code: code, out: capture.out, err: capture.err)
        }
    }

    @Test(.enabled(if: mockPythonAvailable))
    func execAppliesThePolicyAheadOfTheMode() async throws {
        let approved = try await Self.exec(["--deny-all", "--permission-policy", #"{"autoApprove":["edit"]}"#])
        #expect(approved.code == ExitCodes.success)
        #expect(approved.out.contains("outcome:allow"))

        let escalated = try await Self.exec(["--approve-all", "--policy", #"{"escalate":["Edit"]}"#])
        #expect(escalated.code == ExitCodes.permissionDenied)
        #expect(escalated.out.contains("[permission] Permission escalation required for Edit notes.txt\n  sessionId: "))
        #expect(escalated.out.contains("outcome:reject"))
    }

    @Test(.enabled(if: mockPythonAvailable))
    func aPolicyThatDoesNotReadIsAUsageError() async throws {
        let refused = try await Self.exec(["--permission-policy", #"{"defaultAction": "maybe"}"#])
        #expect(refused.code == ExitCodes.usage)
        #expect(refused.err == """
            Invalid permission policy: --permission-policy: permission policy defaultAction must be one of \
            approve, deny, escalate

            """)
        #expect(!refused.out.contains("outcome"))
    }
}
