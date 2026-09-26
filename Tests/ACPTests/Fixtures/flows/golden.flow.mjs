// A flow for comparing SwiftACP's run bundle with acpx's: a title function, outputs
// inline and as JSON and text artifacts, a function action, a switch, and a checkpoint.
import { defineFlow, action, checkpoint, compute } from "acpx/flows";

export default defineFlow({
  name: "golden",
  run: { title: ({ input }) => `Golden ${input.label}` },
  startAt: "prepare",
  nodes: {
    prepare: compute({
      statusDetail: "Preparing items",
      run: ({ input }) => ({ label: input.label, items: Array.from({ length: 30 }, (_, i) => `item-${i}`) }),
    }),
    notes: compute({ run: () => "first line\nsecond line" }),
    act: action({ run: ({ outputs }) => ({ count: outputs.prepare.items.length, route: "review" }) }),
    review: checkpoint({ summary: "Review the items" }),
    skip: compute({ run: () => "skipped" }),
  },
  edges: [
    { from: "prepare", to: "notes" },
    { from: "notes", to: "act" },
    { from: "act", switch: { on: "$.route", cases: { review: "review", skip: "skip" } } },
  ],
});
