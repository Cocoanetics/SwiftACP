#!/usr/bin/env python3
"""A mock ACP agent whose turns fill a session record the way real ones do: thinking in
two chunks, two tool calls — their ids out of sorted order, one completing and one
failing — a reply, and usage, more with each turn.

Every object it sends lists its members sorted, the order SwiftACP keeps an agent's
payloads in, so the record acpx writes for its turns is the one SwiftACP should write
(`acpx-turn-record.json`).
"""
import json
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")
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
                                "status": "pending", "rawInput": {"alpha": 2, "path": "/tmp/n", "zeta": 1}})
            update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "aa-1", "title": "Run ls",
                                "kind": "execute", "status": "in_progress", "rawInput": {"command": "ls"}})
            update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "aa-1", "status": "completed",
                                "rawOutput": {"code": 0, "stdout": "x"}})
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
