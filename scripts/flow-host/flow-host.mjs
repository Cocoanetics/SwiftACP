// SwiftACP's flow host. acpx runs a flow's module inside its own Node process; SwiftACP's
// acpx is a Swift program, so its flow runner starts this host to do the part only a
// JavaScript runtime can: load the flow file, and call the node callbacks the flow
// defines (`run`, `prompt`, `parse`, `exec`, `cwd`, `run.title`). Everything else — the
// graph walk, timeouts, the run bundle — is the runner's.
//
// The runner speaks newline-delimited JSON-RPC 2.0 with this host on a socket, file
// descriptor 3 (or `ACPX_FLOW_FD`), so the flow's own `console.log` and the programs it
// starts keep the terminal, as they do in acpx. `ACPX_FLOW_RUNTIME` names the module a flow imports as "acpx/flows": acpx's
// own authoring helpers (`flow-runtime.mjs`).
//
// The loading follows acpx's `src/flows/cli.ts` (v0.19.3); the definition snapshot its
// `src/flows/store.ts`.
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { pathToFileURL } from "node:url";

const RUNTIME_PATH = process.env.ACPX_FLOW_RUNTIME;
const FLOW_RUNTIME_SPECIFIER = "acpx/flows";
const TEXT_MODULE_EXTENSIONS = new Set([".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"]);
const TYPESCRIPT_EXTENSIONS = new Set([".ts", ".tsx", ".cts", ".mts"]);

// acpx's `TimeoutError` and `InterruptedError` (`src/async-control.ts`): what a callback's
// `ctx.signal` is aborted with.
class TimeoutError extends Error {
  constructor(timeoutMs) {
    super(`Timed out after ${timeoutMs}ms`);
    this.name = "TimeoutError";
  }
}

class InterruptedError extends Error {
  constructor() {
    super("Interrupted");
    this.name = "InterruptedError";
  }
}

const channel = new net.Socket({ fd: Number(process.env.ACPX_FLOW_FD ?? 3), readable: true, writable: true });
// `ACPX_FLOW_HOST_TRACE=1` shows every message on stderr, for debugging the host.
const trace = process.env.ACPX_FLOW_HOST_TRACE ? (label, text) => process.stderr.write(`[flow-host] ${label} ${text}\n`) : null;
const send = (message) => {
  const line = JSON.stringify({ jsonrpc: "2.0", ...message });
  trace?.("->", line);
  channel.write(`${line}\n`);
};

const pending = new Map();
let nextRequestId = 1;
function request(method, params) {
  return new Promise((resolve, reject) => {
    const id = `host-${nextRequestId++}`;
    pending.set(id, { resolve, reject });
    send({ id, method, params });
  });
}

let runtime;
let flow;
let flowPath;
let input;
// `ctx.outputs`: acpx hands every callback the run's own `outputs` object, so what a
// node returned stays the value it returned, not a JSON copy of it.
const outputs = {};
// What each attempt's callback returned last, until the runner makes it the node's output.
const returned = new Map();
const controllers = new Map();

async function loadRuntime() {
  runtime ??= await import(pathToFileURL(RUNTIME_PATH).href);
  return runtime;
}

// acpx's `loadFlowModule`.
async function loadFlow(params) {
  flowPath = params.path;
  const rt = await loadRuntime();
  const extension = path.extname(flowPath).toLowerCase();
  const prepared = await prepareFlowModuleImport(flowPath, extension);
  let module;
  try {
    module = await loadFlowRuntimeModule(prepared.flowPath, extension);
  } finally {
    await prepared.cleanup?.();
  }
  const candidate = findFlowDefinition(rt, module);
  if (!candidate) {
    throw new Error(`Flow module must export default defineFlow({...}) from "acpx/flows": ${flowPath}`);
  }
  rt.__validateFlowDefinition(candidate);
  flow = candidate;
  return describeFlow(flow);
}

// acpx's `prepareFlowModuleImport`: a sibling copy with "acpx/flows" pointed at the runtime.
async function prepareFlowModuleImport(file, extension) {
  if (!TEXT_MODULE_EXTENSIONS.has(extension)) {
    return { flowPath: file };
  }
  const source = await fs.readFile(file, "utf8");
  if (!source.includes(FLOW_RUNTIME_SPECIFIER)) {
    return { flowPath: file };
  }
  const runtimeSpecifier = RUNTIME_PATH.replaceAll(path.sep, "/");
  const rewritten = source.replaceAll(/(["'])acpx\/flows\1/g, (_match, quote) => `${quote}${runtimeSpecifier}${quote}`);
  if (rewritten === source) {
    return { flowPath: file };
  }
  const tempPath = path.join(path.dirname(file), `.acpx-flow-load-${randomUUID()}${extension}`);
  await fs.writeFile(tempPath, rewritten, { mode: 0o600, flag: "wx" });
  return { flowPath: tempPath, cleanup: () => fs.rm(tempPath, { force: true }) };
}

// acpx's `loadFlowRuntimeModule`, where tsx compiles TypeScript: `.ts`, `.tsx` and `.cts`
// to CommonJS, `.mts` as ES modules.
async function loadFlowRuntimeModule(file, extension) {
  if (TYPESCRIPT_EXTENSIONS.has(extension)) {
    throw new Error(
      `TypeScript flow files (${extension}) are not supported by SwiftACP's acpx yet: rename the flow to .mjs, or write it as JavaScript`,
    );
  }
  return await import(pathToFileURL(file).href);
}

function findFlowDefinition(rt, module) {
  const candidates = [
    module.default,
    module["module.exports"],
    nestedDefault(module.default),
    nestedDefault(module["module.exports"]),
  ];
  return candidates.find((candidate) => rt.__isDefinedFlow(candidate)) ?? null;
}

function nestedDefault(value) {
  if (!value || typeof value !== "object" || !("default" in value)) {
    return null;
  }
  return value.default ?? null;
}

// What the runner needs of the flow: acpx's definition snapshot as its `flow.json` has it,
// and each node's settings as the flow gives them.
function describeFlow(definition) {
  const title = definition.run?.title;
  return {
    name: definition.name,
    startAt: definition.startAt,
    edges: definition.edges,
    permissions: definition.permissions ?? null,
    title: typeof title === "string" ? { value: title } : title === undefined ? null : { function: true },
    snapshot: createFlowDefinitionSnapshot(definition),
    nodes: Object.entries(definition.nodes).map(([id, node]) => describeNode(id, node)),
  };
}

function describeNode(id, node) {
  const has = (key) => Object.prototype.hasOwnProperty.call(node, key);
  return {
    id,
    nodeType: node.nodeType,
    ...(node.timeoutMs !== undefined ? { timeoutMs: node.timeoutMs } : {}),
    ...(node.heartbeatMs !== undefined ? { heartbeatMs: node.heartbeatMs } : {}),
    ...(node.statusDetail !== undefined ? { statusDetail: node.statusDetail } : {}),
    ...(node.summary !== undefined ? { summary: node.summary } : {}),
    ...(node.profile !== undefined ? { profile: node.profile } : {}),
    ...(node.session !== undefined
      ? {
          session: {
            ...(node.session.handle !== undefined ? { handle: node.session.handle } : {}),
            isolated: Boolean(node.session.isolated),
          },
        }
      : {}),
    ...(typeof node.cwd === "string" ? { cwd: node.cwd } : {}),
    callbacks: ["run", "prompt", "parse", "exec", "cwd"].filter((key) => typeof node[key] === "function"),
    hasRun: has("run"),
    hasExec: has("exec"),
  };
}

// acpx's `createFlowDefinitionSnapshot` (`src/flows/store.ts`).
function createFlowDefinitionSnapshot(definition) {
  return {
    schema: "acpx.flow-definition-snapshot.v1",
    name: definition.name,
    ...(definition.run?.title !== undefined ? { run: { hasTitle: true } } : {}),
    ...(definition.permissions ? { permissions: structuredClone(definition.permissions) } : {}),
    startAt: definition.startAt,
    nodes: Object.fromEntries(Object.entries(definition.nodes).map(([nodeId, node]) => [nodeId, snapshotNode(node)])),
    edges: structuredClone(definition.edges),
  };
}

function snapshotNode(node) {
  const common = {
    nodeType: node.nodeType,
    ...(node.timeoutMs !== undefined ? { timeoutMs: node.timeoutMs } : {}),
    ...(node.heartbeatMs !== undefined ? { heartbeatMs: node.heartbeatMs } : {}),
    ...(node.statusDetail ? { statusDetail: node.statusDetail } : {}),
  };
  switch (node.nodeType) {
    case "acp":
      return {
        ...common,
        ...(node.profile ? { profile: node.profile } : {}),
        session: {
          ...(node.session?.handle ? { handle: node.session.handle } : {}),
          ...(node.session?.isolated ? { isolated: true } : {}),
        },
        cwd: typeof node.cwd === "function" ? { mode: "dynamic" } : typeof node.cwd === "string" ? { mode: "static", value: node.cwd } : { mode: "default" },
        hasPrompt: true,
        hasParse: typeof node.parse === "function",
      };
    case "compute":
      return { ...common, hasRun: true };
    case "action":
      return {
        ...common,
        actionExecution: "exec" in node ? "shell" : "function",
        hasRun: "run" in node,
        hasExec: "exec" in node,
        hasParse: "parse" in node && typeof node.parse === "function",
      };
    case "checkpoint":
      return { ...common, ...(node.summary ? { summary: node.summary } : {}), hasRun: typeof node.run === "function" };
  }
  throw new Error(`Unsupported flow node type: ${String(node.nodeType)}`);
}

// acpx's `resolveFlowRunTitle`, the part a title function needs.
async function flowTitle(params) {
  const value = await flow.run.title({ input, flowName: flow.name, flowPath: params.flowPath });
  return returnedValue(value);
}

// One node callback, called as acpx's runner calls it, with the step context it builds
// (`makeFlowNodeContext`): the live input and outputs, and a copy of the run state.
async function invoke(params) {
  const { nodeId, fn, attemptId } = params;
  const node = flow.nodes[nodeId];
  const controller = new AbortController();
  controllers.set(attemptId, controller);
  const state = params.state;
  state.input = input;
  state.outputs = outputs;
  const ctx = {
    input,
    outputs,
    results: state.results,
    state,
    services: {},
    signal: controller.signal,
  };
  if (node.nodeType === "action" && "run" in node) {
    ctx.runShell = (execution) => request("shell/run", { attemptId, execution });
  }
  try {
    const args = "arg" in params ? [params.arg, ctx] : [ctx];
    const value = await node[fn](...args);
    returned.set(attemptId, value);
    return returnedValue(value);
  } finally {
    controllers.delete(attemptId);
  }
}

// A callback's value as JSON, as acpx writes it (`JSON.stringify`): nothing for
// `undefined`; `jsonUndefined` for a function or symbol, which `JSON.stringify` makes
// undefined; and the error it throws for one it cannot write (a BigInt, a cycle), which
// acpx's runner fails the step with when it writes the output.
function returnedValue(value) {
  if (value === undefined) {
    return {};
  }
  let json;
  try {
    json = JSON.stringify(value);
  } catch (error) {
    return { unserializable: error instanceof Error ? error.message : String(error) };
  }
  return json === undefined ? { jsonUndefined: true } : { value: JSON.parse(json) };
}

// acpx's `setNodeValue`: the output a node's attempt produced — its callback's value, or
// one the runner made — is the node's output from now on.
function setOutput(params) {
  const value = "value" in params ? params.value : returned.get(params.attemptId);
  Object.defineProperty(outputs, params.nodeId, { value, enumerable: true, configurable: true, writable: true });
}

function cancelAttempt(params) {
  const reason = params.reason === "timeout" ? new TimeoutError(params.timeoutMs) : new InterruptedError();
  controllers.get(params.attemptId)?.abort(reason);
}

// What a callback threw, as acpx's runner records it: the message of an `Error`, else the
// thrown value as a string.
function errorReply(id, error) {
  const isError = error instanceof Error;
  send({
    id,
    error: {
      code: -32000,
      message: isError ? error.message : String(error),
      data: { isError, name: isError ? error.name : null, thrownType: error === null ? "null" : typeof error },
    },
  });
}

async function handle(message) {
  if (message.method === undefined) {
    const waiting = pending.get(message.id);
    pending.delete(message.id);
    if (!waiting) return;
    if (message.error) {
      const error = new Error(message.error.message);
      if (message.error.data?.name) error.name = message.error.data.name;
      waiting.reject(error);
    } else {
      waiting.resolve(message.result);
    }
    return;
  }
  try {
    let result = null;
    switch (message.method) {
      case "flow/load":
        result = await loadFlow(message.params);
        break;
      case "run/start":
        input = message.params.input;
        break;
      case "flow/title":
        result = await flowTitle(message.params);
        break;
      case "node/invoke":
        result = await invoke(message.params);
        break;
      case "outputs/set":
        setOutput(message.params);
        break;
      case "attempt/cancel":
        cancelAttempt(message.params);
        break;
      case "attempt/forget":
        returned.delete(message.params.attemptId);
        break;
      case "host/exit":
        if (message.id !== undefined) send({ id: message.id, result: null });
        channel.end(() => process.exit(0));
        return;
      default:
        throw Object.assign(new Error(`Method not found: ${message.method}`), { code: -32601 });
    }
    if (message.id !== undefined) send({ id: message.id, result });
  } catch (error) {
    if (message.id !== undefined) errorReply(message.id, error);
  }
}

let buffer = "";
channel.setEncoding("utf8");
channel.on("data", (chunk) => {
  buffer += chunk;
  for (let index; (index = buffer.indexOf("\n")) >= 0; ) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (line.trim().length > 0) {
      trace?.("<-", line);
      // Not awaited: the host keeps reading while a callback waits on the runner.
      void handle(JSON.parse(line));
    }
  }
});
channel.on("end", () => process.exit(0));
channel.on("error", () => process.exit(1));

// A terminal's Ctrl-C reaches this process too. The runner handles it, as acpx does,
// and tells the host when to go.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {});
}
