# SwiftACP

A Swift implementation of the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) in a single module — `import SwiftACP` — covering both halves:

- **the client** — the protocol types + a JSON-RPC client (`ACPAgent` /
  `ACPAgentConnection`) for *driving* an ACP agent (the editor/host side).
- **the server** — the agent/server harness for *exposing* an app or CLI **as** an ACP
  agent (`ACPAgentHandler`, `ACPServerSession`, `ACPAgentServer`).

It depends only on `JSONValue` (from [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP)'s
`Client` trait), so it embeds anywhere — a Mac app, an agent CLI, a test. It's the
foundation of **`acpx`**, a headless CLI for driving ACP agents, modelled after the
original [`openclaw/acpx`](https://github.com/openclaw/acpx).

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

## Status

Extracted from ACPX — a byte-faithful Swift clone of
[`openclaw/acpx`](https://github.com/openclaw/acpx) whose CLI/daemon consume these
libraries, and which validates them
(loopback + a mock agent driven by the real ACP client). SwiftAgents' Coder example
exposes itself over ACP via `ACPServer`.

## License

BSD 2-Clause — see [LICENSE](LICENSE).
