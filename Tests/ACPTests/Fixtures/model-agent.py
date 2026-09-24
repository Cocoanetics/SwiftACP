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
and `m2`; the current one stays `m1`.
"""
import json
import os
import sys

LEGACY = os.environ.get("MODEL_AGENT_LEGACY") == "1"
CURRENT = {"model": "m1", "effort": "low"}
MODELS = os.environ.get("MODEL_AGENT_MODELS", "m1,m2").split(",")
NAMES = {"m1": "One", "m2": "Two"}


def config_options():
    return [
        {"id": "model", "type": "select", "category": "model", "name": "Model",
         "currentValue": CURRENT["model"],
         "options": [{"value": model, "name": NAMES.get(model, model)} for model in MODELS]},
        {"id": "effort", "type": "select", "name": "Effort",
         "currentValue": CURRENT["effort"],
         "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]},
    ]


def legacy_models():
    return {"currentModelId": CURRENT["model"],
            "availableModels": [{"modelId": model, "name": NAMES.get(model, model)} for model in MODELS]}


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

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": req_id, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "model-agent", "version": "0.1.0"},
                "agentCapabilities": {"loadSession": False,
                                      "promptCapabilities": {"image": False, "audio": False}},
                "authMethods": []}})
        elif method == "session/new":
            result = {"sessionId": "model-session-1"}
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
                  "result": {} if LEGACY else {"configOptions": config_options()}})
        elif method == "session/set_model":
            CURRENT["model"] = message.get("params", {}).get("modelId", CURRENT["model"])
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})
        elif method == "session/prompt":
            send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
        elif method == "session/cancel":
            pass
        elif req_id is not None:
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32601, "message": "Method not found: %s" % method}})


if __name__ == "__main__":
    main()
