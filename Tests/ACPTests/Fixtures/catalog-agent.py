#!/usr/bin/env python3
"""A mock ACP agent for a session's creation-time catalog, as acpx's own test drives one
(`test/run-once-model-catalog.test.ts`, openclaw/acpx#794).

`CATALOG_AGENT_FIXTURE` names a JSON file holding:
- `initial`: the `session/new` answer;
- `beforeResponse`: `{sessionId, configOptions}` updates sent as `config_option_update`s before
  that answer;
- `afterResponse`: the same, sent right after it;
- `rejectSetter`: when set, `session/set_config_option` and `session/set_model` are answered with
  a -32602 error whose `data` is `{"fixture": <rejectSetter>}`, and message `errorMessage`.

Otherwise a setter is accepted: `session/set_config_option` sets the option's current value and
answers with the options, `session/set_model` with `{}`. A prompt ends its turn. Each request is
appended to the file `CATALOG_AGENT_LOG` names, as a JSON line, with what the agent did with it.
"""
import json
import os
import sys

with open(os.environ["CATALOG_AGENT_FIXTURE"]) as source:
    FIXTURE = json.load(source)
LOG = os.environ["CATALOG_AGENT_LOG"]
config_options = FIXTURE["initial"].get("configOptions", [])


def log(entry):
    with open(LOG, "a") as journal:
        journal.write(json.dumps(entry) + "\n")


def send(message):
    sys.stdout.write(json.dumps(dict(jsonrpc="2.0", **message)) + "\n")
    sys.stdout.flush()


def publish(update):
    global config_options
    send({"method": "session/update", "params": {
        "sessionId": update["sessionId"],
        "update": {"sessionUpdate": "config_option_update", "configOptions": update["configOptions"]}}})
    if update["sessionId"] == FIXTURE["initial"]["sessionId"]:
        config_options = update["configOptions"]


for line in sys.stdin:
    message = json.loads(line)
    method, params, req_id = message.get("method"), message.get("params") or {}, message.get("id")
    if method is None:
        continue
    if method == "initialize":
        send({"id": req_id, "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}})
    elif method == "session/new":
        for update in FIXTURE.get("beforeResponse", []):
            publish(update)
        config_options = FIXTURE["initial"].get("configOptions", [])
        send({"id": req_id, "result": FIXTURE["initial"]})
        for update in FIXTURE.get("afterResponse", []):
            publish(update)
    elif method in ("session/set_config_option", "session/set_model"):
        if FIXTURE.get("rejectSetter"):
            log({"kind": "rejected", "method": method, "params": params})
            send({"id": req_id, "error": {"code": -32602, "message": FIXTURE["errorMessage"],
                                          "data": {"fixture": FIXTURE["rejectSetter"]}}})
            continue
        log({"kind": "accepted", "method": method, "params": params})
        if method == "session/set_config_option":
            config_options = [dict(option, currentValue=params["value"]) if option["id"] == params["configId"]
                              else option for option in config_options]
            send({"id": req_id, "result": {"configOptions": config_options}})
        else:
            send({"id": req_id, "result": {}})
    elif method == "session/prompt":
        log({"kind": "prompt"})
        send({"id": req_id, "result": {"stopReason": "end_turn"}})
    elif req_id is not None:
        send({"id": req_id, "result": {}})
