# SwiftACP

A Swift implementation of the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) in a single module — `import SwiftACP` — covering all three roles:

- **the client** — the protocol types + a JSON-RPC client (`ACPAgent` /
  `ACPAgentConnection`) for *driving* an ACP agent (the editor/host side;
  spawning is desktop-only).
- **the server** — the agent/server harness for *exposing* an app or CLI **as** an ACP
  agent (`ACPAgentHandler`, `ACPServerSession`, `ACPAgentServer`).
- **the daemon client** — the generated `ACPXDaemon.Client` for driving a remote
  `acpxd` session daemon over MCP, on every platform including iOS and Android.

The library builds on
[`JSONFoundation`](https://github.com/Cocoanetics/JSONFoundation) (zero-dependency:
JSON value/schema types and the JSON-RPC runtime) and
[`SwiftMCP`](https://github.com/Cocoanetics/SwiftMCP)'s swift-nio-free MCP client, so
it embeds anywhere — a Mac app, an iOS app, an agent CLI, a test. The same package
also ships the **`acpx`** CLI and **`acpxd`** daemon (macOS-only —
[see below](#the-acpx-cli-and-acpxd-daemon-macos)), a headless toolkit for driving
ACP agents modelled after the original [`openclaw/acpx`](https://github.com/openclaw/acpx).

## Adding the dependency

```swift
.package(url: "https://github.com/Cocoanetics/SwiftACP.git", from: "0.1.0"),
```

with `"SwiftACP"` in your target's dependencies. The default-on `Server` package
trait pulls SwiftMCP's swift-nio server transports (what `acpxd` serves over). A
client-only consumer — an iOS or Android app driving a remote `acpxd` — should
disable it for a swift-nio-free graph:

```swift
.package(url: "https://github.com/Cocoanetics/SwiftACP.git", from: "0.1.0", traits: []),
```

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
`loadSession`, `cancel`, `setMode`, `setConfigOption`, `setModel`, and
`availableCommands` have defaults. `ACPServerSession` streams `session/update`s
(text, reasoning, tool calls, plans), calls back to the client — permission prompts
(`requestPermission`) and file I/O (`readTextFile` / `writeTextFile`) — and exposes
cooperative cancellation. `LoopbackTransport.pair()` (JSONFoundation's in-memory
transport, re-exported by SwiftACP) runs a client and server in the same process
for embedding an agent inside an app or for hermetic tests.

## Drive an agent (client)

```swift
import SwiftACP

let agent = try await ACPAgent.launch(agent: "claude", cwd: repoPath, permission: .approveReads)
let session = try await agent.newSession()
let outcome = try await session.run("Explain this project") { update in render(update) }
print(outcome.text, outcome.stopReason)
await agent.close()
```

Tool-call permission requests are answered by the `PermissionPolicy` (`.approveAll`,
`.approveReads`, `.denyAll`, or a `.custom` resolver). A refusal never ends a turn by
accident: the Codex adapter offers both a `decline` ("continue without running it")
and a `cancel` ("abort the whole turn") one-time refusal — sometimes only `cancel` —
so the connection ranks the non-aborting one first before the policy picks
(`CodexCompat`). When only cancellation is offered it keeps the safe refusal and
explains that it may end the turn, as a `ClientOperation` passed to
`session.run(onClientOperation:)` and as `_meta.acpx.permissionNotice` on the
response. The `acpx` CLI shows the notice as `[permission] …` (text), as
`[acpx] permission: …` on stderr (quiet), or as a JSON line. No operation is ever
approved to keep a turn running.

## The `acpx` CLI and `acpxd` daemon (macOS)

The same package ships a headless CLI and a session daemon built on the library — a
byte-faithful Swift clone of [`openclaw/acpx`](https://github.com/openclaw/acpx) 0.19.1.
They're **macOS-only** (Bonjour service advertisement, POSIX signals) and are gated
behind `#if os(macOS)` in `Package.swift`, so the `SwiftACP` library itself stays
nio-free and keeps building on Linux and Windows.

```sh
swift run acpx claude "explain what this project does"
swift run acpx --approve-reads codex "find and fix the flaky test"
git diff | swift run acpx --format quiet claude -f - "review this diff"
swift run acpx codex sessions new --name backend   # a named session for this directory
swift run acpx codex -s backend "fix the API"      # a turn in it
swift run acpx config show                         # the resolved config
```

As in acpx, the global options (`--approve-reads`, `--format`, `--cwd`, …) go before
the agent or command; after it, each command takes only its own. Everything after an
agent's first prompt word is prompt text.

`acpxd` is the session daemon: an MCP server (Bonjour + local TCP) holding live ACP
sessions, with an optional outward HTTP+SSE transport.

```sh
swift run acpxd                       # Bonjour + local TCP (how the acpx CLI discovers it)
swift run acpxd --http-port 9090 -v   # also expose MCP over HTTP+SSE (unauthenticated — keep on loopback)
```

The CLI and daemon are built on the library plus SwiftMCP's server side: `acpxd` is
an `@MCPServer` whose tools the CLI calls over MCP — the same generated
`ACPXDaemon.Client` an iOS app uses to drive a remote daemon. The extra
executable-only dependencies (service-lifecycle, argument-parser) never reach
consumers of the `SwiftACP` library product.

### MCP servers for a session

`mcpServers` in `~/.acpx/config.json` / `<cwd>/.acpxrc.json` (project replaces global)
are sent on `session/new` and again on every reconnect (`session/load` / `session/resume`),
as in npm acpx. Two ways attach servers to *one session* instead of a working tree:

- `--mcp-config <path>` (CLI, npm parity): a JSON file with the same top-level
  `mcpServers` array, replacing the config-file servers for the invocation. A session
  created under it keeps that set — it is persisted on the record (`acpx.mcp_servers`,
  a SwiftACP extension of the npm record) so `acpxd` replays it on every reconnect.
- `newSession(mcpServers:)` / `setSessionMcpServers(sessionId:mcpServers:)` (daemon
  tools): the same entry shape, inline, for MCP clients such as a dispatcher attaching a
  run-scoped server. `[]` detaches every server; omitting the parameter keeps the
  config-file ones.

A session the daemon holds live does not silently switch servers: `setSessionMcpServers`
refuses, as npm acpx does. Passing `restart` applies the switch anyway by dropping the
adapter — only the local process, so the session is restored with `session/load` and its
history survives, where npm has to close the session outright because its queue owner
*is* the session. The CLI's `--mcp-config` always takes that path, so re-prompting an
existing session with a different config just works; `sessions ensure --mcp-config`
likewise re-attaches to the session it reuses. `sessions show --format json` and
`showSession` list the attached set.

## Status

A byte-faithful Swift clone of
[`openclaw/acpx`](https://github.com/openclaw/acpx), validated by loopback + a mock
agent driven by the real ACP client (`Tests/ACPTests/Fixtures/mock-agent.py`).
SwiftAgents' Coder example exposes itself over ACP via the server half.

## License

BSD 2-Clause — see [LICENSE](LICENSE).
