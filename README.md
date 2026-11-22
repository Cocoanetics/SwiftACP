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

## Toolchain

CI builds every lane with Swift 6.4: Xcode 27.1 on macOS and iOS, and the swift.org
6.4.2 toolchain on Linux, Windows and Android. Tests run on macOS, Linux and Windows;
iOS and Android are build-only. This is the CI setup, not a minimum for consumers — the
package keeps `swift-tools-version: 6.1`.

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

#### MCP server/tool identity (unavailable)

SwiftACP gives no MCP server/tool identity for a tool call, and its permission policies never
derive one. A tool call's adapter-provided `name` and `args` are kept exactly as sent, but they
are opaque and unauthenticated.

- **Captured.** SwiftACP launches Antigravity's external `agy_acp_server` but doesn't vendor
  it. That adapter's sanitized native permission request (#343) carries only a flattened
  `name` (`mcp_missioncontrol_view_issue`), a display `title`
  (`Run mcp_missioncontrol_view_issue`), `kind`, `args` and `rawInput`. It has no
  server/tool pair, and no identity extension has been captured or documented.
- **Required upstream, not implemented.** Identity needs a versioned adapter contract in which
  the trusted adapter sends two things: a unique identifier of an MCP server configured for
  the session, and that server's exact original tool name. The adapter must bind both to that
  configured server/catalog and to the specific call. SwiftACP adds typed access only once
  that wire shape and binding are documented and captured.
- **Never an identity.** None of these establishes the binding: a `title`, `kind`,
  arguments, the `initialize` agent name, or a split of the flattened name.
  `missioncontrol` + `view_issue` and `missioncontrol_view` + `issue` are both readings.
  Even an explicit pair is only the adapter's assertion until the host can check its
  provenance and mapping.
- **Host expectation.** Treat identity as unavailable and fail closed: refuse or ask a person,
  never infer. A shell call's `rawInput` (its `CommandLine`) reaches the handler unchanged for
  the host's command allowlist.

### Record optional observation times

Both `ACPAgent.launch` overloads accept `eventLog: URL? = nil` and
`eventLogTimestampIndex: URL? = nil`. Opt into the companion index explicitly:

```swift
let logURL = runFolder.appendingPathComponent("events.ndjson")
let agent = try await ACPAgent.launch(
    agent: "claude", cwd: repoPath, permission: .approveReads,
    eventLog: logURL,
    eventLogTimestampIndex: logURL.appendingPathExtension("timestamps.ndjson"))
```

The raw log remains exactly `WireJSON.stringified + "\n"` per accepted ACP body.
Without an index URL no sidecar is created. An index requires a raw log and a
different target, including equivalent paths, symlinks and existing hard links;
invalid launch pairs fail before spawning. Recording starts with `initialize`,
survives `agent.rawWire.set(nil)`, and respects replay suppression.

The companion is UTF-8 NDJSON with one LF after each JSON object, for example:

```json
{"crc32":516806862,"direction":"outbound","length":63,"offset":0,"timestamp":"2023-11-14T22:13:20.125Z","version":1}
```

This example matches `{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{}}`
plus LF at the start of the raw log. `version` is the integer `1`. `offset` is a
zero-based UInt64 byte position in the raw file; `length` is a UInt64 byte count
including the final LF. `crc32` is an
unsigned UInt32 JSON integer in decimal: CRC-32/IEEE over those exact bytes
(reflected polynomial `0xEDB88320`, initial and final XOR `0xFFFFFFFF`).
`timestamp` is UTC ISO-8601 with exactly three fractional digits.
`direction`, when known, is `inbound` or `outbound` relative to the client;
otherwise the key is absent. JSON key order is not significant.

Launch captures local wall-clock time on entry to `RawWireTap.observe`, before
parsing or caller callbacks. Outbound observation can precede delivery; inbound
means a body is available. These are neither agent times nor delivery
acknowledgements. Times can tie or move backwards; raw byte offsets retain order.
Direct `ACPEventLogWriter(logURL, timestampIndex: indexURL)` appends capture `Date()`;
`append(body, timestamp: date, direction: .inbound)` permits explicit values.

Copies and observer closures share one synchronized writer. One logical writer
owns the pair; simultaneous independent writers or processes are unsupported.
Each append reads the actual file end and writes the complete raw line before its
metadata. Torn raw tails are preserved; an append starting inside an unterminated
line gets no metadata. A torn index tail is separated by LF before later records.
Index errors preserve raw output and never fail transport; direct appends report
the error after any successful raw write. A crash can leave raw lines without
metadata: closing per append is neither a two-file transaction nor an `fsync`
guarantee. Archive/copy the files together and discard the index when replacing
the raw log. Existing replay and raw-only archive exports are unchanged.

### Replay with observation times

`ACPEventLogReader(logURL).entries()` and `entries(in: data)` retain their original
typed replay and never read an index. Opt into metadata explicitly:

```swift
let reader = ACPEventLogReader(
    logURL, timestampIndex: logURL.appendingPathExtension("timestamps.ndjson"))
let entries = try reader.entriesWithTimes() // ACPEventLogTimedEntry: entry + metadata
let messages = try reader.messagesWithTimes() // ACPEventLogTimedMessage: message + metadata
// Snapshot equivalents: entriesWithTimes(in: rawData, timestampIndex: indexData)
// and messagesWithTimes(in: rawData, timestampIndex: indexData).
```

Each envelope exposes `timestamp: Date?`, client-relative `direction`, and
`byteOffset: UInt64`. Raw replay includes initialize and permission requests/replies
that typed replay filters out. For example, when recording a permission refusal
independently, retain its local `Date`, request id and session id. During replay,
find the corresponding raw request and its cancellation reply:

```swift
let permissionRequests = messages.filter {
    $0.message["method"]?.stringValue == "session/request_permission"
}
for request in permissionRequests {
    let requestID = request.message["id"]
    let cancellation = messages.first {
        $0.byteOffset > request.byteOffset && $0.direction == .outbound &&
        $0.message["id"] == requestID &&
        $0.message["result"]?["outcome"]?["outcome"]?.stringValue == "cancelled"
    }
    // Match your refusal's request/session ids; use request.timestamp and
    // cancellation?.timestamp as local observations alongside the refusal's Date.
}
```

Use request/session identity and direction when correlating: both peers can use
the same JSON-RPC id. A cancellation alone does not prove a policy refusal.
Times have millisecond precision, can tie or move backwards, and cannot establish
an exact order with independently recorded events. Keep ACP messages in file order
using byte offsets; choose and document an external-event tie policy (for example,
display a matched refusal beside its request when their times tie).

The reader snapshots raw bytes before reading the index. Missing or unusable index
records yield nil time/direction only at affected offsets, including stale checksums
and conflicting duplicates. A valid final JSON line without LF still replays with
nil metadata. `SessionArchive` history remains raw ACP: archives alone do not
preserve this optional sidecar. Copy both files to retain observation metadata.

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

Session cleanup deliberately departs from acpx for safety: `sessions prune` lists
matching closed sessions and requires `--yes` before deleting anything, including
on a terminal. Without it, the command previews candidates and fails without writes;
`--dry-run` is a successful preview and never deletes, even with `--yes`.
Prune is scoped to the selected agent (the default agent when omitted), across
working directories; `--before <date>` or `--older-than <days>` narrows it by age.

```sh
swift run acpx codex sessions prune --dry-run --older-than 30
swift run acpx codex sessions prune --yes --older-than 30 --include-history
swift run acpx sessions remove <record-id> --include-history
```

`sessions remove <id>` deletes exactly the full local record ID shown by
`sessions list --local`, across agents and directories. Names, provider session IDs
and abbreviated IDs are refused. An open session is closed through the existing
session lifecycle first. Both cleanup commands preserve event streams unless
`--include-history` is supplied; use `ACPX_HOME` pointing at a temporary directory
for smoke tests so they never write into your real session store.

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
