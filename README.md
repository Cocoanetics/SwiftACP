# SwiftACP

A Swift implementation of the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) in a single module — `import SwiftACP` — covering both halves:

- **the client** — the protocol types + a JSON-RPC client (`ACPAgent` /
  `ACPAgentConnection`) for *driving* an ACP agent (the editor/host side).
- **the server** — the agent/server harness for *exposing* an app or CLI **as** an ACP
  agent (`ACPAgentHandler`, `ACPServerSession`, `ACPAgentServer`).

The library depends only on the zero-dependency
[`JSONFoundation`](https://github.com/Cocoanetics/JSONFoundation) package, so it embeds
anywhere — a Mac app, an agent CLI, a test. The same package also ships the **`acpx`**
CLI and **`acpxd`** daemon (macOS-only — [see below](#the-acpx-cli-and-acpxd-daemon-macos)),
a headless toolkit for driving ACP agents modelled after the original
[`openclaw/acpx`](https://github.com/openclaw/acpx).

## Expose an agent (server)

```swift
import SwiftACP

struct MyHandler: ACPAgentHandler {
    func initialize(_ request: InitializeRequest) async -> InitializeResponse {
        InitializeResponse(agentInfo: Implementation(name: "my-agent", version: "1.0"))
    }
    func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: UUID().uuidString)
    }
    func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
        await session.sendText("Hello!")
        return PromptResponse(stopReason: .endTurn,
                              usage: PromptUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12))
    }
}

@main enum Main {
    static func main() async throws {
        try await ACPAgentServer.serveStdio(handler: MyHandler())   // speaks ACP over stdin/stdout
    }
}
```

Only `initialize`, `newSession`, and `prompt` are required; `authenticate`,
`loadSession`, `cancel`, `setMode`, and `setConfigOption` have defaults.
`ACPServerSession` streams `session/update`s (text, reasoning, tool calls, plans),
calls back to the client (permission prompts, file I/O), and exposes cooperative
cancellation. `LoopbackTransport.pair()` runs a client and server in the same
process for embedding or hermetic tests.

## Drive an agent (client)

```swift
import SwiftACP

let agent = try await ACPAgent.launch(agent: "claude", cwd: repoPath, permission: .approveReads)
let session = try await agent.newSession()
let outcome = try await session.run("Explain this project") { update in render(update) }
print(outcome.text, outcome.stopReason)
await agent.close()
```

## The `acpx` CLI and `acpxd` daemon (macOS)

The same package ships a headless CLI and a session daemon built on the library — a
byte-faithful Swift clone of [`openclaw/acpx`](https://github.com/openclaw/acpx) 0.11.0.
They're **macOS-only** (Bonjour service advertisement, POSIX signals) and are gated
behind `#if os(macOS)` in `Package.swift`, so the `SwiftACP` library itself stays
nio-free and keeps building on Linux and Windows.

```sh
swift run acpx claude "explain what this project does"
swift run acpx codex --approve-reads "find and fix the flaky test"
git diff | swift run acpx claude -q "review this diff"
swift run acpx chat codex          # interactive multi-turn session
swift run acpx agents              # list known agents + resolved launch commands
```

`acpxd` is the session daemon: an MCP server (Bonjour + local TCP) holding live ACP
sessions, with an optional outward HTTP+SSE transport.

```sh
swift run acpxd                       # Bonjour + local TCP (how the acpx CLI discovers it)
swift run acpxd --http-port 9090 -v   # also expose MCP over HTTP+SSE (unauthenticated — keep on loopback)
```

The CLI/daemon pull in `SwiftMCP` (+ swift-nio, service-lifecycle, argument-parser),
so depending only on the `SwiftACP` library on macOS will resolve those into your
graph; off-Apple platforms get just `SwiftACP` + `JSONFoundation`.

## Status

A byte-faithful Swift clone of
[`openclaw/acpx`](https://github.com/openclaw/acpx), validated by loopback + a mock
agent driven by the real ACP client (`Tests/ACPTests/Fixtures/mock-agent.py`).
SwiftAgents' Coder example exposes itself over ACP via the server half.

## License

BSD 2-Clause — see [LICENSE](LICENSE).
