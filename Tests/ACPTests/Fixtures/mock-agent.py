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
import time


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

# A FIFO a `session/load` reads to its end before it is answered: a test knows the
# agent is loading once it can open the FIFO to write, and lets it go by closing it.
LOAD_GATE = os.environ.get("MOCK_LOAD_GATE")

# A prompt is held until `session/cancel` comes, then answered `cancelled`.
HOLD_UNTIL_CANCEL = bool(os.environ.get("MOCK_HOLD_UNTIL_CANCEL"))

# A path. A prompt opens a terminal that runs until the path exists, asks for the
# terminal's exit without awaiting the answer, and then answers: the turn has a request of
# the client open past its answer, until a test creates the path. (Files, not FIFOs: a
# test creates one without blocking, so no step of it waits where cancelling cannot reach.)
HOLD_TERMINAL = os.environ.get("MOCK_HOLD_TERMINAL")

# A path, with MOCK_HOLD_TERMINAL. Once the prompt is answered, the agent waits for it to
# exist, then asks a permission question; answered, it creates MOCK_HOLD_TERMINAL itself.
ASK_AFTER_ANSWER = os.environ.get("MOCK_ASK_AFTER_ANSWER")


def wait_for(path):
    while not os.path.exists(path):
        time.sleep(0.02)

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

    # "env NAME": NAME's value in the agent's environment, to show what it was started with.
    if text.strip().startswith("env "):
        name = text.strip()[len("env "):]
        session_update(session_id, {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "%s=%s" % (name, os.environ.get(name, "<unset>"))},
        })
        send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
        return

    # "gone turn": a partial reply, then a session-gone error.
    if text.strip() == "gone turn":
        session_update(session_id, {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "partial "},
        })
        send({"jsonrpc": "2.0", "id": req_id, "error": {
            "code": -32002, "message": "Resource not found: session %s" % session_id}})
        return

    # "fail turn": a partial reply, then the agent's error response, with details.
    if text.strip() == "fail turn":
        session_update(session_id, {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "partial "},
        })
        send({"jsonrpc": "2.0", "id": req_id, "error": {
            "code": -32603, "message": "Internal error", "data": {"details": "model overloaded"}}})
        return

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

    # MOCK_LATE_CHUNK: one more reply chunk, 200 ms after the answer.
    late = os.environ.get("MOCK_LATE_CHUNK")
    if late:
        time.sleep(0.2)
        session_update(session_id, {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": late}})


def main():
    # MOCK_ARGV_LOG: each launch appends the arguments it was given, so a test can see
    # exactly what the client spawned.
    argv_log = os.environ.get("MOCK_ARGV_LOG")
    if argv_log:
        with open(argv_log, "a", encoding="utf-8") as output:
            output.write(json.dumps(sys.argv[1:]) + "\n")
    prompts_answered = 0
    held_prompt = None
    terminal_prompt, terminal_session = None, None
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

        # The answers to the agent's own requests (MOCK_HOLD_TERMINAL).
        if method is None and req_id == "mock-terminal-create":
            send({"jsonrpc": "2.0", "id": "mock-terminal-wait", "method": "terminal/wait_for_exit", "params": {
                "sessionId": terminal_session, "terminalId": message.get("result", {}).get("terminalId")}})
            respond(terminal_prompt, {"stopReason": "end_turn"})
            if ASK_AFTER_ANSWER:
                wait_for(ASK_AFTER_ANSWER)
                send({"jsonrpc": "2.0", "id": "mock-ask", "method": "session/request_permission", "params": {
                    "sessionId": terminal_session,
                    "toolCall": {"toolCallId": "call-ask", "title": "a question after the answer"},
                    "options": [
                        {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                    ]}})
            continue
        if method is None and req_id == "mock-ask":
            open(HOLD_TERMINAL, "w", encoding="utf-8").close()
            continue
        if method is None and str(req_id).startswith("mock-"):
            continue

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
            # MOCK_NEW_META / MOCK_LOAD_META: the `_meta` (JSON) of the replies that
            # open a session, where an agent names its own session id.
            result = {"sessionId": SESSION_ID}
            if os.environ.get("MOCK_NEW_META"):
                result["_meta"] = json.loads(os.environ["MOCK_NEW_META"])
            respond(req_id, result)
        elif method == "session/load" and LOAD_MODE != "unsupported":
            # `gone` (the default) is the usual reason a fresh agent process cannot
            # load a session: it no longer has it. `ok` takes it back; `internal`
            # fails the way an agent's own bug would.
            if LOAD_GATE:
                with open(LOAD_GATE) as gate:
                    gate.read()
            if LOAD_MODE == "ok":
                loaded = message.get("params", {}).get("sessionId", SESSION_ID)
                if LOAD_REPLAY:
                    session_update(loaded, {"sessionUpdate": "user_message_chunk",
                                            "content": {"type": "text", "text": "replayed question"}})
                    session_update(loaded, {"sessionUpdate": "agent_message_chunk",
                                            "content": {"type": "text", "text": "replayed answer"}})
                respond(req_id, {"_meta": json.loads(os.environ["MOCK_LOAD_META"])}
                        if os.environ.get("MOCK_LOAD_META") else {})
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
            if HOLD_UNTIL_CANCEL:
                held_prompt = req_id
                continue
            if HOLD_TERMINAL:
                terminal_prompt = req_id
                terminal_session = message.get("params", {}).get("sessionId")
                send({"jsonrpc": "2.0", "id": "mock-terminal-create", "method": "terminal/create", "params": {
                    "sessionId": terminal_session, "command": "/bin/sh",
                    "args": ["-c", 'while [ ! -e "$1" ]; do sleep 0.02; done', "hold", HOLD_TERMINAL]}})
                continue
            handle_prompt(req_id, message.get("params", {}))
            if EXIT_AFTER_PROMPTS and prompts_answered >= EXIT_AFTER_PROMPTS:
                sys.stdout.flush()
                os._exit(0)
        elif method == "session/set_mode":
            # MOCK_SET_MODE_ERROR: refuse every mode, with details.
            if os.environ.get("MOCK_SET_MODE_ERROR"):
                send({"jsonrpc": "2.0", "id": req_id, "error": {
                    "code": -32603, "message": "Internal error", "data": {"details": "mode unavailable"}}})
                continue
            # Echo the new mode back as a current_mode_update, then ack.
            params = message.get("params", {})
            session_update(params.get("sessionId", "mock-session-1"),
                           {"sessionUpdate": "current_mode_update",
                            "currentModeId": params.get("modeId", "")})
            respond(req_id, {})
        elif method == "session/set_config_option":
            # MOCK_SET_CONFIG_OPTION_ERROR: refuse every option, with details.
            if os.environ.get("MOCK_SET_CONFIG_OPTION_ERROR"):
                send({"jsonrpc": "2.0", "id": req_id, "error": {
                    "code": -32602, "message": "Invalid params", "data": {"details": "option unavailable"}}})
                continue
            respond(req_id, {})
        elif method == "session/set_model":
            respond(req_id, {})
        elif method == "session/cancel":
            if held_prompt is not None:
                respond(held_prompt, {"stopReason": "cancelled"})
                held_prompt = None
        elif req_id is not None:
            # Unknown request: report method-not-found.
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": "Method not found: %s" % method}})


if __name__ == "__main__":
    main()
