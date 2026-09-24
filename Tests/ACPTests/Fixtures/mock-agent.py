#!/usr/bin/env python3
"""A tiny mock ACP agent for hermetic tests and demos.

Speaks the agent side of the Agent Client Protocol over stdio (newline-delimited
JSON-RPC 2.0). It implements just enough to exercise a client end to end:
initialize -> session/new -> session/prompt, streaming a plan, a tool call and
agent message chunks before returning a stop reason.

It deliberately uses no third-party packages so it runs anywhere Python 3 does.
"""
import base64
import json
import os
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


# How `session/load` behaves: gone (default) | ok | internal | unsupported.
LOAD_MODE = os.environ.get("MOCK_LOAD_SESSION", "gone")

# A `session/load` it takes back first replays the session's history as updates, as
# real adapters do, and sends one more straight after answering, as some do.
LOAD_REPLAY = bool(os.environ.get("MOCK_LOAD_REPLAY"))

# After this many answered prompts, this process drops its sessions: later prompts
# fail the way an agent answers for a session it no longer has, while the client
# still holds the connection. A relaunched process remembers again. 0 = never.
FORGET_AFTER_PROMPTS = int(os.environ.get("MOCK_FORGET_AFTER_PROMPTS", "0"))

# After this many answered prompts, this process exits — an adapter that crashed or
# was killed between turns, while its client still holds the connection. 0 = never.
EXIT_AFTER_PROMPTS = int(os.environ.get("MOCK_EXIT_AFTER_PROMPTS", "0"))

# Exit on receiving the Nth prompt, without answering it — an adapter that crashes
# mid-turn, after the prompt reached it. 0 = never.
EXIT_ON_PROMPT = int(os.environ.get("MOCK_EXIT_ON_PROMPT", "0"))

# Each process names its sessions after itself, so a replacement session is
# distinguishable from the one it replaced. Off: every session is mock-session-1.
SESSION_ID = ("mock-session-%d" % os.getpid()) if os.environ.get("MOCK_SESSION_ID_PER_PROCESS") \
    else "mock-session-1"


def log_request(message):
    path = os.environ.get("MOCK_REQUEST_LOG")
    if path and message.get("method", "").startswith("session/"):
        with open(path, "a", encoding="utf-8") as output:
            output.write(json.dumps(message) + "\n")


def handle_prompt(req_id, params):
    session_id = params.get("sessionId", "mock-session")
    # Pull the user's text out of the prompt content blocks, and summarize any
    # non-text ones so a test can prove they arrived intact.
    text = ""
    attachments = []
    for block in params.get("prompt", []):
        if block.get("type") == "text":
            text += block.get("text", "")
        elif block.get("type") == "image":
            attachments.append("[image %s %d bytes]" % (
                block.get("mimeType", "?"),
                len(base64.b64decode(block.get("data", ""))),
            ))

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
    if attachments:
        reply += " with " + " ".join(attachments)
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
    # MOCK_ARGV_LOG: each launch appends the arguments it was given, so a test can see
    # exactly what the client spawned.
    argv_log = os.environ.get("MOCK_ARGV_LOG")
    if argv_log:
        with open(argv_log, "a", encoding="utf-8") as output:
            output.write(json.dumps(sys.argv[1:]) + "\n")
    prompts_answered = 0
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
        log_request(message)

        if method == "initialize":
            respond(req_id, {
                "protocolVersion": 1,
                "agentInfo": {"name": "mock-agent", "version": "0.1.0"},
                # MOCK_IMAGE_CAPABLE flips the one capability that gates image
                # prompt blocks, so tests can drive both sides of that gate.
                "agentCapabilities": {
                    # MOCK_LOAD_SESSION picks how `session/load` behaves (see below);
                    # only `unsupported` stops advertising it.
                    "loadSession": LOAD_MODE != "unsupported",
                    "promptCapabilities": {
                        "image": bool(os.environ.get("MOCK_IMAGE_CAPABLE")),
                        "audio": False,
                    },
                },
                "authMethods": [],
            })
        elif method == "session/new":
            respond(req_id, {"sessionId": SESSION_ID})
        elif method == "session/load" and LOAD_MODE != "unsupported":
            # `gone` (the default) is the usual reason a fresh agent process cannot
            # load a session: it no longer has it. `ok` takes it back; `internal`
            # fails the way an agent's own bug would.
            if LOAD_MODE == "ok":
                loaded = message.get("params", {}).get("sessionId", SESSION_ID)
                if LOAD_REPLAY:
                    session_update(loaded, {"sessionUpdate": "user_message_chunk",
                                            "content": {"type": "text", "text": "replayed question"}})
                    session_update(loaded, {"sessionUpdate": "agent_message_chunk",
                                            "content": {"type": "text", "text": "replayed answer"}})
                respond(req_id, {})
                if LOAD_REPLAY:
                    session_update(loaded, {"sessionUpdate": "agent_message_chunk",
                                            "content": {"type": "text", "text": "replayed late"}})
            elif LOAD_MODE == "internal":
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32603, "message": "Internal error"}})
            else:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32002, "message": "Resource not found: session %s"
                                % message.get("params", {}).get("sessionId", "?")}})
        elif method == "session/prompt":
            if FORGET_AFTER_PROMPTS and prompts_answered >= FORGET_AFTER_PROMPTS:
                send({"jsonrpc": "2.0", "id": req_id,
                      "error": {"code": -32002, "message": "Resource not found: session %s"
                                % message.get("params", {}).get("sessionId", "?")}})
                continue
            if EXIT_ON_PROMPT and prompts_answered + 1 >= EXIT_ON_PROMPT:
                os._exit(0)
            prompts_answered += 1
            handle_prompt(req_id, message.get("params", {}))
            if EXIT_AFTER_PROMPTS and prompts_answered >= EXIT_AFTER_PROMPTS:
                sys.stdout.flush()
                os._exit(0)
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
