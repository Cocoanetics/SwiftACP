#!/usr/bin/env python3
"""A mock ACP agent that advertises session config options.

Complements `mock-agent.py` (which advertises none) so the model/config-option
application path can be driven end to end: it answers `session/new` with a
`model` select plus a plain `effort` select, echoes the updated set back from
every `session/set_config_option`, and appends each request it received to
`$MODEL_AGENT_LOG` so a test can assert the order they arrived in.

`MODEL_AGENT_LEGACY=1` switches it to the legacy shape instead — no config
options, a `models` block, and `session/set_model` as the only model control.
`MODEL_AGENT_MODELS` (comma-separated ids) replaces the advertised models, `m1`
and `m2`; the current one stays `m1`. `MODEL_AGENT_MODELS_FILE` names a file holding
that list instead, read at launch, so a test can change what a later launch offers.
`MODEL_AGENT_LOAD=1` makes it take sessions back with `session/load`, answering with
what `session/new` would. `session/set_mode` is accepted. `MODEL_AGENT_EXIT_ON_MODEL`
names a file: while it exists, the next model request removes it and the agent exits
without answering. `MODEL_AGENT_EMPTY_REPLIES=1` answers `session/set_config_option` with
`{}`, reporting no options back. `MODEL_AGENT_MODEL_ERROR` holds an error object the model's
request (`session/set_model`, or the `model` option) is answered with. `MODEL_AGENT_EXTRA_OPTION` names one more select to
advertise after `effort`, with the values `x` (current) and `y`. During a prompt,
`MODEL_AGENT_COMMANDS=1` sends an `available_commands_update` and `MODEL_AGENT_MODE_UPDATE`
a `current_mode_update` to the mode it names, before the answer.
"""
import json
import os
import sys

LEGACY = os.environ.get("MODEL_AGENT_LEGACY") == "1"
LOAD = os.environ.get("MODEL_AGENT_LOAD") == "1"
CURRENT = {"model": "m1", "effort": "low"}
MODELS_FILE = os.environ.get("MODEL_AGENT_MODELS_FILE")
if MODELS_FILE and os.path.exists(MODELS_FILE):
    MODELS = open(MODELS_FILE).read().strip().split(",")
else:
    MODELS = os.environ.get("MODEL_AGENT_MODELS", "m1,m2").split(",")
NAMES = {"m1": "One", "m2": "Two"}
EXIT_ON_MODEL = os.environ.get("MODEL_AGENT_EXIT_ON_MODEL")
EMPTY_REPLIES = os.environ.get("MODEL_AGENT_EMPTY_REPLIES") == "1"
MODEL_ERROR = os.environ.get("MODEL_AGENT_MODEL_ERROR")
EXTRA = os.environ.get("MODEL_AGENT_EXTRA_OPTION")
if EXTRA:
    CURRENT[EXTRA] = "x"


def config_options():
    return [
        {"id": "model", "type": "select", "category": "model", "name": "Model",
         "currentValue": CURRENT["model"],
         "options": [{"value": model, "name": NAMES.get(model, model)} for model in MODELS]},
        {"id": "effort", "type": "select", "name": "Effort",
         "currentValue": CURRENT["effort"],
         "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]},
    ] + ([{"id": EXTRA, "type": "select", "name": EXTRA, "currentValue": CURRENT[EXTRA],
           "options": [{"value": "x", "name": "X"}, {"value": "y", "name": "Y"}]}] if EXTRA else [])


def legacy_models():
    return {"currentModelId": CURRENT["model"],
            "availableModels": [{"modelId": model, "name": NAMES.get(model, model)} for model in MODELS]}


def exits_on(method, params):
    """Whether this is the model request `MODEL_AGENT_EXIT_ON_MODEL` armed the agent to die on."""
    if not EXIT_ON_MODEL or not os.path.exists(EXIT_ON_MODEL):
        return False
    if method == "session/set_model" or (
            method == "session/set_config_option" and params.get("configId") == "model"):
        os.remove(EXIT_ON_MODEL)
        return True
    return False


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(message):
    path = os.environ.get("MODEL_AGENT_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as output:
            output.write(json.dumps(message) + "\n")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        log(message)
        method, req_id = message.get("method"), message.get("id")
        if exits_on(method, message.get("params", {})):
            sys.exit(3)
        if MODEL_ERROR and (method == "session/set_model" or (
                method == "session/set_config_option" and message.get("params", {}).get("configId") == "model")):
            send({"jsonrpc": "2.0", "id": req_id, "error": json.loads(MODEL_ERROR)})
            continue

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "model-agent", "version": "0.1.0"},
                "agentCapabilities": {"loadSession": LOAD,
                                      "promptCapabilities": {"image": False, "audio": False}},
                "authMethods": []}})
        elif method in ("session/new", "session/load"):
            result = {} if method == "session/load" else {"sessionId": "model-session-1"}
            if LEGACY:
                result["models"] = legacy_models()
            else:
                result["configOptions"] = config_options()
            send({"jsonrpc": "2.0", "id": req_id, "result": result})
        elif method == "session/set_config_option":
            params = message.get("params", {})
            if params.get("configId") in CURRENT:
                CURRENT[params["configId"]] = params.get("value")
            send({"jsonrpc": "2.0", "id": req_id,
                  "result": {} if LEGACY or EMPTY_REPLIES else {"configOptions": config_options()}})
        elif method == "session/set_mode":
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif method == "session/set_model":
            CURRENT["model"] = message.get("params", {}).get("modelId", CURRENT["model"])
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif method == "session/prompt":
            session_id = message.get("params", {}).get("sessionId")
            if os.environ.get("MODEL_AGENT_COMMANDS") == "1":
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": session_id, "update": {
                        "sessionUpdate": "available_commands_update",
                        "availableCommands": [{"name": "debug", "description": "Debug the session"}]}}})
            if os.environ.get("MODEL_AGENT_MODE_UPDATE"):
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": session_id, "update": {
                        "sessionUpdate": "current_mode_update",
                        "currentModeId": os.environ["MODEL_AGENT_MODE_UPDATE"]}}})
            send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
        elif method == "session/cancel":
            pass
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": "Method not found: %s" % method}})


if __name__ == "__main__":
    main()
