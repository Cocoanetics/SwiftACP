import Foundation
import JSONRPCWire
import SwiftACP
import Testing

/// Covers the codex `CODEX_PATH` fallback and the bumped adapter pin — both
/// added so the codex agent survives macOS XProtect quarantining codex-acp's
/// bundled `@openai/codex` build (issue #11 / openclaw/acpx#434).
struct AgentRegistryTests {
    // MARK: - injectingCodexPath (pure, PATH-free)

    @Test func injectsCodexPathWhenAbsent() {
        // A custom environment is a full replacement, so it must gain CODEX_PATH
        // while every other inherited var is left intact.
        let env = AgentRegistry.injectingCodexPath(
            codexBinary: "/opt/bin/codex", environment: ["PATH": "/usr/bin", "HOME": "/h"])
        #expect(env?["CODEX_PATH"] == "/opt/bin/codex")
        #expect(env?["PATH"] == "/usr/bin")
        #expect(env?["HOME"] == "/h")
    }

    @Test func respectsExplicitCodexPath() {
        // An explicit CODEX_PATH always wins — including one deliberately pointing
        // at the bundled build — so the fallback must never overwrite it.
        let env = AgentRegistry.injectingCodexPath(
            codexBinary: "/opt/bin/codex", environment: ["CODEX_PATH": "/custom/codex"])
        #expect(env?["CODEX_PATH"] == "/custom/codex")
    }

    @Test func noOpWhenNoSystemCodex() {
        // No codex on PATH → environment returned untouched (here: nil/inherit).
        #expect(AgentRegistry.injectingCodexPath(codexBinary: nil, environment: nil) == nil)
        let custom = ["PATH": "/usr/bin"]
        #expect(AgentRegistry.injectingCodexPath(codexBinary: nil, environment: custom) == custom)
    }

    // MARK: - launch wiring

    @Test func launchLeavesNonCodexEnvironmentUntouched() {
        // The PATH scan / CODEX_PATH injection is gated on the codex key.
        let spec = AgentRegistry.launch(for: "claude", environment: ["A": "B"])
        #expect(spec.environment?["CODEX_PATH"] == nil)
        #expect(spec.environment?["A"] == "B")
    }

    @Test func launchPreservesCallerCodexPath() {
        // Exercising the real codex launch path: an explicit CODEX_PATH survives.
        let spec = AgentRegistry.launch(
            for: "codex", environment: ["CODEX_PATH": "/pinned/codex", "PATH": "/usr/bin"])
        #expect(spec.environment?["CODEX_PATH"] == "/pinned/codex")
    }

    // MARK: - adapter pin

    @Test func codexAdapterPinnedAheadOfBundledFlaggedBuild() {
        // Guards the XProtect fix from a silent revert to acpx's `^0.0.44` (which
        // bundles the quarantined codex 0.128.0). See issue #11.
        #expect(AgentRegistry.PackageRange.codex == "^1.1.0")
        #expect(AgentRegistry.builtIn["codex"] == "npx -y @agentclientprotocol/codex-acp@^1.1.0")
    }
}
