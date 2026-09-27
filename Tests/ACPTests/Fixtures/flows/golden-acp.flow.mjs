// ACP nodes as `theAcpBundleIsWrittenAsAcpxWritesIt` runs them, against the fixture agent
// (`mock-agent.py`, the flow's `mock` profile): each turn in an isolated session, none with
// a periodic heartbeat, which a slow machine's turn could outlast.
// `record-golden-acp.py` recorded acpx 0.19.3's run of it (`golden-acp-acpx-0.19.3.json`).
import { defineFlow, acp, checkpoint, compute } from "acpx/flows";

export default defineFlow({
  name: "golden-acp",
  run: { title: ({ input }) => `ACP ${input.topic}` },
  startAt: "plan",
  nodes: {
    // The agent's whole turn: a plan, a tool call, the reply in chunks, a usage update,
    // and the prompt's usage, which acpx reports on stderr.
    plan: acp({
      profile: "mock",
      heartbeatMs: 0,
      session: { isolated: true },
      prompt: ({ input }) => `plan the ${input.topic}\nwith care`,
      parse: (text) => ({ reply: text, words: text.split(" ").length }),
    }),
    // Content blocks, in a directory of the flow's choosing, the node's own detail.
    blocks: acp({
      profile: "mock",
      heartbeatMs: 0,
      statusDetail: "Sending blocks",
      cwd: ({ input }) => input.dir,
      session: { isolated: true },
      prompt: ({ outputs }) => [
        { type: "text", text: `blocks after ${outputs.plan.words} words` },
        { type: "resource_link", uri: "file:///golden/notes.txt", name: "notes.txt" },
      ],
    }),
    // The agent's error, after part of a reply, which the flow routes on.
    risky: acp({ profile: "mock", heartbeatMs: 0, session: { isolated: true }, prompt: () => "fail turn" }),
    recover: compute({
      heartbeatMs: 0,
      run: ({ results }) => ({ outcome: results.risky.outcome, error: results.risky.error }),
    }),
    review: checkpoint({ summary: "Check the replies" }),
  },
  edges: [
    { from: "plan", to: "blocks" },
    { from: "blocks", to: "risky" },
    { from: "risky", switch: { on: "$result.outcome", cases: { failed: "recover", ok: "recover" } } },
    { from: "recover", to: "review" },
  ],
});
