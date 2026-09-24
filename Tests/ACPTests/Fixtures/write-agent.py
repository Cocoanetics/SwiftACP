#!/usr/bin/env python3
"""A mock ACP agent that, on every prompt, asks the client to write a file.

It writes `<cwd>/written.txt` and answers the turn with what the client said: `ok`,
or `error:<data.details or message>`. That makes a turn's permission mode observable
from the daemon's aggregate reply, without an MCP session to catch log events.

With `MOCK_READ` set it reads `<cwd>/notes.txt` instead, and answers `ok:<content>`
or the error. With `MOCK_TOOL_PERMISSION` set it asks permission for an edit tool,
and answers `outcome:<selected option, or cancelled>`. With `MOCK_TERMINAL` set to a
JSON array — a command and its arguments — it runs that through the client's
terminal, waits for it, reads its output, releases it, and answers
`ran:<exit code>:<output>`, or the first error. A `session/set_mode` runs it too, before
answering, and appends that line to `$MOCK_TERMINAL_LOG`. With `MOCK_TERMINAL_ON_INITIALIZE`
set, `initialize` starts it instead, waits for it to print something, logs that, and fails.
"""
import json
import os
import sys
import time

cwd = None
pending = None
terminal = None
exit_status = None
output = None
TERMINAL = os.environ.get("MOCK_TERMINAL")
TERMINAL_LOG = os.environ.get("MOCK_TERMINAL_LOG")
# What the terminal is run for: "prompt", or "set_mode".
running_for = None


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def say(session_id, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": session_id,
        "update": {"sessionUpdate": "agent_message_chunk",
                   "content": {"type": "text", "text": text}}}})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method, req_id = message.get("method"), message.get("id")
    if method == "initialize" and TERMINAL and os.environ.get("MOCK_TERMINAL_ON_INITIALIZE"):
        pending = (req_id, "init")
        running_for = "initialize"
        argv = json.loads(TERMINAL)
        send({"jsonrpc": "2.0", "id": "term-create", "method": "terminal/create", "params": {
            "sessionId": "init", "command": argv[0], "args": argv[1:]}})
    elif method is None and running_for == "initialize" and str(req_id).startswith("term-"):
        # Poll the output until the command has printed, then fail `initialize`.
        result = message.get("result") or {}
        if req_id == "term-create":
            terminal = result.get("terminalId")
        elif result.get("output"):
            if TERMINAL_LOG:
                with open(TERMINAL_LOG, "a") as log:
                    log.write(result["output"])
            send({"jsonrpc": "2.0", "id": pending[0],
                  "error": {"code": -32603, "message": "initialize failed on purpose"}})
            continue
        else:
            time.sleep(0.02)
        send({"jsonrpc": "2.0", "id": "term-poll", "method": "terminal/output",
              "params": {"sessionId": "init", "terminalId": terminal}})
    elif method == "initialize":
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "protocolVersion": 1, "agentInfo": {"name": "write-agent", "version": "0.1.0"},
            "agentCapabilities": {"loadSession": False, "promptCapabilities": {}},
            "authMethods": []}})
    elif method in ("session/new", "session/load"):
        cwd = message["params"]["cwd"]
        send({"jsonrpc": "2.0", "id": req_id,
              "result": {"sessionId": message["params"].get("sessionId", "write-session")}})
    elif method == "session/set_mode" and TERMINAL:
        pending = (req_id, message["params"]["sessionId"])
        running_for = "set_mode"
        argv = json.loads(TERMINAL)
        send({"jsonrpc": "2.0", "id": "term-create", "method": "terminal/create", "params": {
            "sessionId": pending[1], "command": argv[0], "args": argv[1:]}})
    elif method == "session/set_mode":
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif method == "session/prompt":
        pending = (req_id, message["params"]["sessionId"])
        running_for = "prompt"
        if TERMINAL:
            argv = json.loads(TERMINAL)
            send({"jsonrpc": "2.0", "id": "term-create", "method": "terminal/create", "params": {
                "sessionId": pending[1], "command": argv[0], "args": argv[1:]}})
        elif os.environ.get("MOCK_TOOL_PERMISSION"):
            send({"jsonrpc": "2.0", "id": "write", "method": "session/request_permission", "params": {
                "sessionId": pending[1],
                "toolCall": {"toolCallId": "t1", "title": "Edit notes.txt", "kind": "edit"},
                "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                            {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]}})
        elif os.environ.get("MOCK_READ"):
            send({"jsonrpc": "2.0", "id": "write", "method": "fs/read_text_file", "params": {
                "sessionId": pending[1], "path": os.path.join(cwd, "notes.txt")}})
        else:
            send({"jsonrpc": "2.0", "id": "write", "method": "fs/write_text_file", "params": {
                "sessionId": pending[1], "path": os.path.join(cwd, "written.txt"), "content": "hi"}})
    elif method is None and str(req_id).startswith("term-"):
        error = message.get("error")
        # Each answer sends the next request: create, wait, output, release.
        following = {"term-create": ("term-wait", "terminal/wait_for_exit"),
                     "term-wait": ("term-output", "terminal/output"),
                     "term-output": ("term-release", "terminal/release")}.get(req_id)
        if req_id == "term-create" and not error:
            terminal = message["result"]["terminalId"]
        elif req_id == "term-wait" and not error:
            exit_status = message["result"]
        elif req_id == "term-output" and not error:
            output = message["result"]["output"]
        if error or following is None:
            if error:
                line = "error:" + ((error.get("data") or {}).get("details") or error.get("message"))
            else:
                line = "ran:%s:%s" % (exit_status["exitCode"], output)
            if running_for == "set_mode":
                if TERMINAL_LOG:
                    with open(TERMINAL_LOG, "a") as log:
                        log.write(line + "\n")
                send({"jsonrpc": "2.0", "id": pending[0], "result": {}})
            else:
                say(pending[1], line)
                send({"jsonrpc": "2.0", "id": pending[0], "result": {"stopReason": "end_turn"}})
        else:
            send({"jsonrpc": "2.0", "id": following[0], "method": following[1],
                  "params": {"sessionId": pending[1], "terminalId": terminal}})
    elif req_id == "write" and method is None:
        error = message.get("error")
        if error:
            details = (error.get("data") or {}).get("details") or error.get("message")
            say(pending[1], "error:" + details)
        elif os.environ.get("MOCK_TOOL_PERMISSION"):
            outcome = message["result"]["outcome"]
            say(pending[1], "outcome:" + outcome.get("optionId", outcome["outcome"]))
        elif os.environ.get("MOCK_READ"):
            say(pending[1], "ok:" + message["result"]["content"])
        else:
            say(pending[1], "ok")
        send({"jsonrpc": "2.0", "id": pending[0], "result": {"stopReason": "end_turn"}})
    elif req_id is not None and method is not None:
        send({"jsonrpc": "2.0", "id": req_id,
              "error": {"code": -32601, "message": "Method not found: %s" % method}})
