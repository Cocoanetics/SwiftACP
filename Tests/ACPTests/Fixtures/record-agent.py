#!/usr/bin/env python3
"""A mock ACP agent whose turns fill a session record the way real ones do: thinking in
two chunks, two tool calls — their ids out of sorted order, one completing and one
failing — a reply, and usage, more with each turn.

Every object it sends lists its members sorted (`acpx-turn-record.json`). With
RECORD_AGENT_AS_WRITTEN set, it writes them as its code lists them, and its tools' input and
output out of sorted order, which acpx records as the agent sent them
(`acpx-turn-record-as-written.json`, #119).
"""
import json
import os
import sys

AS_WRITTEN = bool(os.environ.get("RECORD_AGENT_AS_WRITTEN"))


def send(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=not AS_WRITTEN) + "\n")
    sys.stdout.flush()


def update(session_id, value):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": value}})


def main():
    turns = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        method, req_id = message.get("method"), message.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "agentCapabilities": {"loadSession": True,
                                      "promptCapabilities": {"audio": False, "embeddedContext": True, "image": True}},
                "authMethods": [], "protocolVersion": 1}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "record-session"}})
        elif method == "session/load":
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif method == "session/prompt":
            session_id = message["params"]["sessionId"]
            turns += 1
            update(session_id, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Let me "}})
            update(session_id, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "think."}})
            update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "zz-2", "title": "Read notes", "kind": "read",
                                "status": "pending", "rawInput": {"path": "/tmp/n", "zeta": 1, "alpha": 2}})
            update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "aa-1", "title": "Run ls",
                                "kind": "execute", "status": "in_progress", "rawInput": {"command": "ls"}})
            update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "aa-1", "status": "completed",
                                "rawOutput": {"stdout": "x", "code": 0}})
            update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "zz-2", "status": "failed",
                                "rawOutput": "no such file"})
            update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done."}})
            update(session_id, {"sessionUpdate": "usage_update", "cost": {"amount": 0.5 * turns, "currency": "USD"},
                                "size": 1000, "used": 100 * turns})
            send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn", "usage": {
                "inputTokens": 10 * turns, "outputTokens": 20 * turns, "totalTokens": 30 * turns}}})
        elif method == "session/cancel":
            pass
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": "Method not found"}})


if __name__ == "__main__":
    main()
