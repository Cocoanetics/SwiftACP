#!/usr/bin/env python3
"""A mock ACP agent for `--timeout` and `--prompt-retries`: what it does is set by
`RETRY_AGENT_MODE`.

- `hang-init`, `hang-new`, `hang-prompt`: never answers `initialize`, `session/new` or
  `session/prompt`. `hang-model` and `hang-effort` never answer the
  `session/set_config_option` for the `model` or `effort` option it advertises.
- `fail-once`: its first prompt fails with ACP's internal error (-32603, details
  `model overloaded`), as a model API's hiccup does; later prompts answer. `fail-always`
  fails every prompt that way.
- `fail-after-update`, `fail-after-read`, `fail-after-bad-read`, `fail-after-permission`:
  first sends an update, reads `<cwd>/notes.txt`, reads `notes.txt` (a path the client
  refuses), or asks permission to edit — then fails as `fail-once` does.
- `fail-then-update`: fails as `fail-once` does, and sends an update 300 ms later —
  inside the pause before a retry. `fail-then-ask` asks permission to edit then instead,
  and `fail-then-write` writes `<cwd>/out.txt`.
- `fail-auth-once`: its first prompt fails with -32000 (authentication required).
- `fail-after-updates`: sends twenty updates, then fails as `fail-once` does.
  `burst-then-hang` sends them and never answers.

Otherwise a prompt answers `hello`. Each prompt appends a line to the file
`RETRY_AGENT_ATTEMPTS` names, and the agent writes its pid to `RETRY_AGENT_PID` on start.
"""
import json
import os
import sys
import time

MODE = os.environ.get("RETRY_AGENT_MODE", "ok")
ATTEMPTS = os.environ.get("RETRY_AGENT_ATTEMPTS")
if os.environ.get("RETRY_AGENT_PID"):
    with open(os.environ["RETRY_AGENT_PID"], "w") as handle:
        handle.write(str(os.getpid()))
OPTIONS = [
    {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "a",
     "options": [{"value": "a", "name": "A"}, {"value": "b", "name": "B"}]},
    {"id": "effort", "name": "Effort", "type": "select", "currentValue": "low",
     "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]},
]
cwd = None
next_id = 1000


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def ask(method, params):
    """Send a request to the client and read on until its answer."""
    global next_id
    next_id += 1
    send({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params})
    for line in sys.stdin:
        if line.strip() and json.loads(line).get("id") == next_id:
            return


def update(session_id, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


def ask_to_edit(session_id):
    ask("session/request_permission", {"sessionId": session_id, "toolCall": {
        "toolCallId": "edit-1", "title": "Edit notes", "kind": "edit", "status": "pending"},
        "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]})


def fail(req_id, code=-32603, message="Internal error", details="model overloaded"):
    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message,
                                                     "data": {"details": details}}})


def prompt(req_id, session_id):
    first = True
    if ATTEMPTS:
        first = not os.path.exists(ATTEMPTS)
        with open(ATTEMPTS, "a") as handle:
            handle.write("prompt\n")
    if MODE == "burst-then-hang":
        for index in range(20):
            update(session_id, "u%d " % index)
    if MODE in ("hang-prompt", "burst-then-hang"):
        time.sleep(60)
    if first or MODE == "fail-always":
        if MODE == "fail-after-update":
            update(session_id, "partial ")
        elif MODE == "fail-after-updates":
            for index in range(20):
                update(session_id, "u%d " % index)
        elif MODE == "fail-after-read":
            ask("fs/read_text_file", {"sessionId": session_id, "path": os.path.join(cwd, "notes.txt")})
        elif MODE == "fail-after-bad-read":
            ask("fs/read_text_file", {"sessionId": session_id, "path": "notes.txt"})
        elif MODE == "fail-after-permission":
            ask_to_edit(session_id)
        if MODE == "fail-auth-once":
            return fail(req_id, -32000, "Authentication required", "login first")
        if MODE.startswith("fail-"):
            fail(req_id)
            if MODE == "fail-then-update":
                time.sleep(0.3)
                update(session_id, "late ")
            elif MODE == "fail-then-ask":
                time.sleep(0.3)
                ask_to_edit(session_id)
            elif MODE == "fail-then-write":
                time.sleep(0.3)
                ask("fs/write_text_file", {"sessionId": session_id, "path": os.path.join(cwd, "out.txt"),
                                           "content": "x"})
            return
    update(session_id, "hello")
    send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})


for line in sys.stdin:
    if not line.strip():
        continue
    message = json.loads(line)
    method, req_id, params = message.get("method"), message.get("id"), message.get("params", {})
    if method == "initialize":
        if MODE == "hang-init":
            time.sleep(60)
        send({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif method == "session/new":
        if MODE == "hang-new":
            time.sleep(60)
        cwd = params.get("cwd")
        send({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "retry-session", "configOptions": OPTIONS}})
    elif method == "session/set_config_option":
        if MODE == "hang-%s" % params.get("configId"):
            time.sleep(60)
        send({"jsonrpc": "2.0", "id": req_id, "result": {"configOptions": OPTIONS}})
    elif method == "session/prompt":
        prompt(req_id, params.get("sessionId"))
    elif req_id is not None and method is not None:
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
