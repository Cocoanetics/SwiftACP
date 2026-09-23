#!/usr/bin/env python3
"""A mock ACP agent that, on every prompt, asks the client to write a file.

It writes `<cwd>/written.txt` and answers the turn with what the client said: `ok`,
or `error:<data.details or message>`. That makes a turn's permission mode observable
from the daemon's aggregate reply, without an MCP session to catch log events.
"""
import json
import os
import sys

cwd = None
pending = None


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
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": req_id, "result": {
            "protocolVersion": 1, "agentInfo": {"name": "write-agent", "version": "0.1.0"},
            "agentCapabilities": {"loadSession": False, "promptCapabilities": {}},
            "authMethods": []}})
    elif method in ("session/new", "session/load"):
        cwd = message["params"]["cwd"]
        send({"jsonrpc": "2.0", "id": req_id,
              "result": {"sessionId": message["params"].get("sessionId", "write-session")}})
    elif method == "session/prompt":
        pending = (req_id, message["params"]["sessionId"])
        send({"jsonrpc": "2.0", "id": "write", "method": "fs/write_text_file", "params": {
            "sessionId": pending[1], "path": os.path.join(cwd, "written.txt"), "content": "hi"}})
    elif req_id == "write" and method is None:
        error = message.get("error")
        if error:
            details = (error.get("data") or {}).get("details") or error.get("message")
            say(pending[1], "error:" + details)
        else:
            say(pending[1], "ok")
        send({"jsonrpc": "2.0", "id": pending[0], "result": {"stopReason": "end_turn"}})
    elif req_id is not None and method is not None:
        send({"jsonrpc": "2.0", "id": req_id,
              "error": {"code": -32601, "message": "Method not found: %s" % method}})
