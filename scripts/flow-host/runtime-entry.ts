// The module a flow file imports as "acpx/flows" under SwiftACP's acpx: acpx's own
// authoring helpers, unchanged, from the acpx release `build.sh` names (MIT). The flow
// runner itself is SwiftACP's, in Swift, so `FlowRunner` is not here to use.
import os from "node:os";
import path from "node:path";

export { acp, action, checkpoint, compute, defineFlow, shell } from "./src/flows/definition.js";
export { decision, decisionEdge } from "./src/flows/decision.js";
export { extractJsonObject, parseJsonObject, parseStrictJsonObject } from "./src/flows/json.js";

// acpx's `flowRunsBaseDir` (`src/flows/store.ts`).
export function flowRunsBaseDir(homeDir: string = os.homedir()): string {
  return path.join(homeDir, ".acpx", "flows", "runs");
}

export class FlowRunner {
  constructor() {
    throw new Error("FlowRunner is not available to a flow run by SwiftACP's acpx");
  }
}

// For the flow host only: how acpx's loader recognizes and checks a flow.
export { isDefinedFlow as __isDefinedFlow } from "./src/flows/authoring.js";
export { validateFlowDefinition as __validateFlowDefinition } from "./src/flows/graph.js";
