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
try await agent.close()
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

The CLI starts `acpxd` when it needs one (`--on-demand`). That daemon stops by itself once it has
held no session and served no call for ten seconds. It holds each session until the session's
`--ttl` runs out, as acpx's queue owner exits after its TTL. A daemon started any other way —
by hand, by launchd, or hosted in an app — runs until it is stopped.

A CLI that stops reading what `acpxd` sends it holds only its own call, as with acpx's queue
owner: its turn goes on, and the next prompt on the session runs. `acpxd` disconnects a CLI that
leaves its output unread for ten seconds, or whose unsent output passes 64 MiB (256 MiB across all
CLIs, and 64 CLIs with output unsent). That CLI then reports `Queue owner disconnected before
prompt completion; outcome unknown`. acpx allows a second; over TCP a slow reader's progress shows
only in bursts seconds apart. acpx holds these limits for each session's owner, spooling to temp
files; `acpxd` holds the output in memory, so they hold for all its sessions together.

The CLI works only through an `acpxd` of its own version, which the daemon reports in MCP's
`serverInfo`: SwiftACP's release and a fingerprint of the daemon's tools. With another running —
one of an earlier release, or one whose tools have changed since — the CLI runs nothing and says
how to restart it. Builds of one release with the same tools are not told apart.

The CLI and daemon are built on the library plus SwiftMCP's server side: `acpxd` is
an `@MCPServer` whose tools the CLI calls over MCP — the same generated
`ACPXDaemon.Client` an iOS app uses to drive a remote daemon. The extra
executable-only dependencies (service-lifecycle, argument-parser) never reach
consumers of the `SwiftACP` library product.

### MCP servers for a session

As in acpx, a session's MCP servers are each invocation's own, and the record keeps none:
`mcpServers` in `~/.acpx/config.json` / `<cwd>/.acpxrc.json` (project replaces global), or
`--mcp-config <path>` — a JSON file with the same top-level `mcpServers` array, which replaces
both for the invocation.

- `sessions new` gives them to the agent that creates the session.
- A prompt that starts the session's owner gives the owner its servers (and its credentials):
  every agent the owner connects, a reconnect included, gets them until the owner goes, at its
  `--ttl`. A later prompt is refused, as acpx refuses it, unless it names the owner's
  `--mcp-config` file with the same servers, or no file where the owner had none:
  `Session queue owner uses a different MCP config; close the session before retrying`
  (`QUEUE_MCP_CONFIG_CONFLICT`).
- A control (`set-mode`, `set`) is never refused over its config. With no owner, it connects with
  its own; under an owner, with the owner's.

The daemon's tools take the same entry shape for MCP clients: each prompt and control can bring
its config (`callerConfig`), and `newSession(mcpServers:)` gives servers to the creating agent.

### Flows

`acpx flow run <file>` runs an acpx flow — a module that does `export default
defineFlow({...})` from `"acpx/flows"` — as acpx 0.19.3 runs it, and writes the same run
bundle under `~/.acpx/flows/runs/`. The runner is Swift. The flow's own code runs in
Node (22.13 or later, found on `PATH`), which acpx itself needs: the CLI starts a small
host script with it, and `"acpx/flows"` resolves to acpx's own authoring helpers,
bundled into the CLI (`scripts/flow-host`).

```sh
swift run acpx flow run review.flow.mjs --input-json '{"pr": 42}'
```

TypeScript flows compile with sucrase, to CommonJS as acpx's tsx does (`.mts` as an ES
module). So far compute, function action and checkpoint nodes run; shell actions and ACP
nodes follow (#202).

### The acpx skill

`acpx --skill` serves the skill acpx bundles for coding agents, as acpx serves it with
[skillflag](https://github.com/osolmaz/skillflag). The skill is acpx 0.19.3's
`skills/acpx/SKILL.md`, embedded in the CLI; it describes acpx, whose commands and flags this
CLI shares.

```sh
swift run acpx --skill list
swift run acpx --skill show acpx
swift run acpx --skill install acpx --agent codex --scope user   # into ~/.codex/skills/acpx
swift run acpx --skill export acpx > acpx-skill.tar
```

`install` puts the skill where each agent keeps its skills: `--agent` is one of codex, claude,
portable, vscode, copilot, amp, goose, opencode, factory or cursor, and `--scope` one of repo,
user or cwd. Without either, it asks for them on the terminal in acpx's wizard, drawn as acpx
draws it with @clack/prompts. With standard input piped, it asks on `/dev/tty`. With no terminal
at all, it reports the missing flags. `scripts/skill/embed.sh` embeds the skill of another acpx
release.

## Status

A byte-faithful Swift clone of
[`openclaw/acpx`](https://github.com/openclaw/acpx), validated by loopback + a mock
agent driven by the real ACP client (`Tests/ACPTests/Fixtures/mock-agent.py`).
SwiftAgents' Coder example exposes itself over ACP via the server half.

## License

BSD 2-Clause — see [LICENSE](LICENSE). The `acpx` CLI embeds acpx's skill
(`skills/acpx/SKILL.md`, MIT, © 2025 OpenClaw Team) with its license, in
`Sources/acpx/BundledSkill.swift`.
