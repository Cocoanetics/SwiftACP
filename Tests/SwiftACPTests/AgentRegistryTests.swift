import Foundation
import JSONRPCWire
import SwiftACP
import Testing

/// Covers the codex `CODEX_PATH` fallback and the bumped adapter pin — both
/// added so the codex agent survives macOS XProtect quarantining codex-acp's
/// bundled `@openai/codex` build (issue #11 / openclaw/acpx#434).
struct AgentRegistryTests {
    // MARK: - injectingCodexPath (pure, filesystem-free via an injected lookup)

    @Test func injectsCodexPathWhenAbsent() {
        // A custom environment is a full replacement, so it must gain CODEX_PATH
        // while every other inherited var is left intact.
        let env = AgentRegistry.injectingCodexPath(
            environment: ["PATH": "/usr/bin", "HOME": "/h"], resolveCodex: { _ in "/opt/bin/codex" })
        #expect(env?["CODEX_PATH"] == "/opt/bin/codex")
        #expect(env?["PATH"] == "/usr/bin")
        #expect(env?["HOME"] == "/h")
    }

    @Test func respectsExplicitCodexPathWithoutScanning() {
        // An explicit CODEX_PATH always wins — including one deliberately pointing
        // at the bundled build — AND short-circuits before the (filesystem) scan.
        var scanned = false
        let env = AgentRegistry.injectingCodexPath(
            environment: ["CODEX_PATH": "/custom/codex", "PATH": "/usr/bin"],
            resolveCodex: { _ in
                scanned = true
                return "/opt/bin/codex"
            })
        #expect(env?["CODEX_PATH"] == "/custom/codex")
        #expect(scanned == false)
    }

    @Test func searchesTheChildEnvironmentPath() {
        // The lookup must see the PATH the child will run with, not the parent's.
        var seenPath: String?
        _ = AgentRegistry.injectingCodexPath(
            environment: ["PATH": "/opt/toolchain/bin"],
            resolveCodex: { path in
                seenPath = path
                return nil
            })
        #expect(seenPath == "/opt/toolchain/bin")
    }

    @Test func noOpWhenNoSystemCodex() {
        // No codex found → environment returned untouched (nil stays nil/inherit).
        #expect(AgentRegistry.injectingCodexPath(environment: nil, resolveCodex: { _ in nil }) == nil)
        let custom = ["PATH": "/usr/bin"]
        #expect(
            AgentRegistry.injectingCodexPath(environment: custom, resolveCodex: { _ in nil }) == custom)
    }

    // MARK: - launch wiring

    @Test func launchLeavesNonCodexEnvironmentUntouched() {
        // The CODEX_PATH injection is gated on the codex key.
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

    @Test func launchInjectsSystemCodexForCodexAgent() {
        // Integration check of the launch → injection wiring for the absent case.
        // Skips on machines without a system codex so it stays green in minimal CI.
        guard let systemCodex = AgentRegistry.which("codex") else { return }
        let spec = AgentRegistry.launch(
            for: "codex", environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""])
        #expect(spec.environment?["CODEX_PATH"] == systemCodex)
    }

    // MARK: - adapter pin

    @Test func codexAdapterPinnedAheadOfFlaggedBuild() {
        // The XProtect-quarantined codex 0.128.0 ships in codex-acp `^0.0.44`
        // (issue #11); assert the pin has moved off it — but not to one exact
        // literal, so a legitimate future bump doesn't force a test edit.
        #expect(AgentRegistry.PackageRange.codex != "^0.0.44")
        let codexCommand = AgentRegistry.builtIn["codex"]
        #expect(codexCommand?.contains("@agentclientprotocol/codex-acp@") == true)
        #expect(codexCommand?.contains("^0.0.44") == false)
    }

    // MARK: - registry parity

    /// The built-in list, in upstream's `AGENT_DEFINITIONS` declaration order — which
    /// is also the order `--help` prints. Pinned deliberately: a clone that silently
    /// drifts from the registry it mirrors is the bug this asserts against, so adding
    /// an agent upstream should force a conscious edit here.
    ///
    @Test func builtInAgentsMatchUpstreamOrder() {
        #expect(
            AgentRegistry.orderedNames == [
                "pi", "openclaw", "codex", "claude", "gemini", "cursor", "copilot",
                "antigravity", "devin", "droid", "fast-agent", "fx", "grok-build", "iflow",
                "junie", "kilocode", "kimi", "kiro", "mcode", "mux", "opencode", "pool", "qoder",
                "qwen", "trae", "zeroclaw"
            ])
        #expect(Set(AgentRegistry.orderedNames).count == AgentRegistry.orderedNames.count)
        #expect(AgentRegistry.builtIn.count == AgentRegistry.orderedNames.count)
    }

    @Test func factoryDroidAliasesResolve() {
        #expect(AgentRegistry.aliases["factory-droid"] == "droid")
        #expect(AgentRegistry.aliases["factorydroid"] == "droid")
    }
}
