#!/usr/bin/env python3
"""A tiny mock ACP agent for hermetic tests and demos.

Speaks the agent side of the Agent Client Protocol over stdio (newline-delimited
JSON-RPC 2.0). It implements just enough to exercise a client end to end:
initialize -> session/new -> session/prompt, streaming a plan, a tool call and
agent message chunks before returning a stop reason.

It deliberately uses no third-party packages so it runs anywhere Python 3 does.
"""
import json
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def respond(req_id, result):
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


def session_update(session_id, update):
    notify("session/update", {"sessionId": session_id, "update": update})


def handle_prompt(req_id, params):
    session_id = params.get("sessionId", "mock-session")
    # Pull the user's text out of the prompt content blocks.
    text = ""
    for block in params.get("prompt", []):
        if block.get("type") == "text":
            text += block.get("text", "")

    # A short plan.
    session_update(session_id, {
        "sessionUpdate": "plan",
        "entries": [
            {"content": "Read the request", "status": "completed", "priority": "high"},
            {"content": "Compose a reply", "status": "in_progress", "priority": "medium"},
        ],
    })

    # A tool call lifecycle.
    session_update(session_id, {
        "sessionUpdate": "tool_call",
        "toolCallId": "call-1",
        "title": "echo",
        "kind": "other",
        "status": "in_progress",
    })
    session_update(session_id, {
        "sessionUpdate": "tool_call_update",
        "toolCallId": "call-1",
        "status": "completed",
    })

    # Stream the reply word by word as agent_message_chunk.
    reply = "Hello from the mock agent! You said: " + text.strip()
    for word in reply.split(" "):
        session_update(session_id, {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": word + " "},
        })

    # Report cost on a usage_update (where Claude Code carries cost), with the
    # bare {used, size} context metric and no _meta.usage — exactly as real agents do.
    session_update(session_id, {
        "sessionUpdate": "usage_update",
        "used": 100, "size": 200000,
        "cost": {"amount": 0.0042, "currency": "USD"},
    })

    # Report a token breakdown on the response (where Claude Code carries it).
    respond(req_id, {
        "stopReason": "end_turn",
        "usage": {
            "inputTokens": 12, "outputTokens": 34, "cachedReadTokens": 5,
            "cachedWriteTokens": 6, "totalTokens": 57,
        },
    })


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = message.get("method")
        req_id = message.get("id")

        if method == "initialize":
            respond(req_id, {
                "protocolVersion": 1,
                "agentInfo": {"name": "mock-agent", "version": "0.1.0"},
                "agentCapabilities": {"loadSession": False,
                                      "promptCapabilities": {"image": False, "audio": False}},
                "authMethods": [],
            })
        elif method == "session/new":
            respond(req_id, {"sessionId": "mock-session-1"})
        elif method == "session/prompt":
            handle_prompt(req_id, message.get("params", {}))
        elif method == "session/set_mode":
            # Echo the new mode back as a current_mode_update, then ack.
            params = message.get("params", {})
            session_update(params.get("sessionId", "mock-session-1"),
                           {"sessionUpdate": "current_mode_update",
                            "currentModeId": params.get("modeId", "")})
            respond(req_id, {})
        elif method == "session/set_config_option":
            respond(req_id, {})
        elif method == "session/set_model":
            respond(req_id, {})
        elif method == "session/cancel":
            pass  # notification, nothing to do
        elif req_id is not None:
            # Unknown request: report method-not-found.
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": "Method not found: %s" % method}})


if __name__ == "__main__":
    main()
