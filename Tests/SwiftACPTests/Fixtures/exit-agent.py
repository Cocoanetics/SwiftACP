#!/usr/bin/env python3
"""A mock ACP agent that ends in the ways an adapter can, for the agent transport.

- `EXIT_AGENT_ON=initialize|prompt|set_mode` exits at that request without answering it, with
  `EXIT_AGENT_CODE` (3 by default) — or, with `EXIT_AGENT_SIGNAL=KILL|TERM|...`, by that
  signal — after writing `EXIT_AGENT_STDERR` to stderr. On a prompt it first streams
  the text `partial `.
- `EXIT_AGENT_ARMED=<path>`: while that file exists, the next prompt removes it and
  exits as `EXIT_AGENT_ON=prompt` does.
- `EXIT_AGENT_ANSWER_THEN_EXIT=1` answers each prompt, then exits 0 at once.
- `EXIT_AGENT_HOLD=1` never answers a prompt, once it has streamed `partial `.
- `EXIT_AGENT_CLOSE_STDOUT=1` closes its stdout at a prompt and keeps running; `=set_mode`
  does so at `session/set_mode` instead.
- `EXIT_AGENT_CLOSE_STDIN=1` closes its stdin once it has answered `session/new`, and keeps
  running.
- `EXIT_AGENT_CLOSE_STDIN_ARMED=<path>`: while that file exists, the next prompt removes it
  and closes its stdin before answering, and the agent keeps running.
- `EXIT_AGENT_STRAY=1` writes lines that are no message before answering a prompt: JSON
  values that are no object, a batch, a stray object, and text that is no JSON.
- `EXIT_AGENT_LINE_BYTES=N` answers `initialize` with a line of N bytes, LF excluded.
- `EXIT_AGENT_INIT_ERROR=1` answers `initialize` with an error, and runs on.
- `EXIT_AGENT_AUTH=1` advertises a sign-in method on `initialize`.
- `EXIT_AGENT_STUBBORN=1` ignores `SIGTERM` and keeps running once its stdin ends.
- `EXIT_AGENT_CHILD=<path>` starts `sleep 300` at `initialize` — or at the method
  `EXIT_AGENT_CHILD_AT` names — ignoring `SIGTERM` like itself, and writes its pid to the
  path.
"""
import json
import os
import signal
import subprocess
import sys
import time

ON = os.environ.get("EXIT_AGENT_ON", "")
CODE = int(os.environ.get("EXIT_AGENT_CODE", "3"))
SIGNAL = os.environ.get("EXIT_AGENT_SIGNAL", "")
STDERR = os.environ.get("EXIT_AGENT_STDERR", "")
STUBBORN = os.environ.get("EXIT_AGENT_STUBBORN") == "1"
LINE_BYTES = int(os.environ.get("EXIT_AGENT_LINE_BYTES", "0"))

if STUBBORN:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def die():
    if STDERR:
        sys.stderr.write(STDERR)
        sys.stderr.flush()
    if SIGNAL:
        os.kill(os.getpid(), getattr(signal, "SIG" + SIGNAL))
    os._exit(CODE)


def initialize_result(req_id):
    result = {"protocolVersion": 1, "agentInfo": {"name": "exit-agent", "version": "0.1.0"},
              "agentCapabilities": {"loadSession": True}, "authMethods": []}
    if os.environ.get("EXIT_AGENT_AUTH") == "1":
        result["authMethods"] = [{"id": "probe-login", "name": "Probe login"}]
    answer = {"jsonrpc": "2.0", "id": req_id, "result": result}
    if os.environ.get("EXIT_AGENT_INIT_ERROR") == "1":
        answer = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32603, "message": "init refused"}}
    if LINE_BYTES:
        result["pad"] = ""
        result["pad"] = "a" * (LINE_BYTES - len(json.dumps(answer)))
    send(answer)


def start_child():
    child = os.environ.get("EXIT_AGENT_CHILD")
    if child:
        sleeper = subprocess.Popen(
            ["/bin/sh", "-c", "trap '' TERM; exec sleep 300"], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(child, "w") as output:
            output.write(str(sleeper.pid))


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        method, req_id = message.get("method"), message.get("id")
        if method == os.environ.get("EXIT_AGENT_CHILD_AT", "initialize"):
            start_child()
        if method == "initialize":
            if ON == "initialize":
                die()
            initialize_result(req_id)
        elif method in ("session/new", "session/load"):
            result = {"sessionId": "exit-session"} if method == "session/new" else {}
            send({"jsonrpc": "2.0", "id": req_id, "result": result})
            if os.environ.get("EXIT_AGENT_CLOSE_STDIN") == "1":
                os.close(0)
                time.sleep(30)
                os._exit(0)
        elif method == "session/prompt":
            session_id = message["params"]["sessionId"]
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial "}}}})
            armed = os.environ.get("EXIT_AGENT_ARMED")
            if ON == "prompt" or (armed and os.path.exists(armed)):
                if armed and os.path.exists(armed):
                    os.remove(armed)
                die()
            if os.environ.get("EXIT_AGENT_HOLD") == "1":
                continue
            if os.environ.get("EXIT_AGENT_CLOSE_STDOUT") in ("1", "prompt"):
                os.close(1)
                time.sleep(30)
                os._exit(0)
            if os.environ.get("EXIT_AGENT_STRAY") == "1":
                update = {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {
                    "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "batched"}}}}
                for stray in ["42", '"x"', "null", "[1]", json.dumps([update]), '{"stray":true}', "not json"]:
                    sys.stdout.write(stray + "\n")
                sys.stdout.flush()
            closing = os.environ.get("EXIT_AGENT_CLOSE_STDIN_ARMED")
            if closing and os.path.exists(closing):
                os.remove(closing)
                os.close(0)
                send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
                time.sleep(30)
                os._exit(0)
            send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
            if os.environ.get("EXIT_AGENT_ANSWER_THEN_EXIT") == "1":
                os._exit(0)
        elif method == "session/set_mode":
            if ON == "set_mode":
                die()
            if os.environ.get("EXIT_AGENT_CLOSE_STDOUT") == "set_mode":
                os.close(1)
                time.sleep(30)
                os._exit(0)
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif method == "session/cancel":
            pass
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": "Method not found"}})
    if STUBBORN:
        while True:
            time.sleep(1)


if __name__ == "__main__":
    main()
