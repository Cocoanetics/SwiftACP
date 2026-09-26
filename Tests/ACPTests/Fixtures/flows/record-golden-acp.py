#!/usr/bin/env python3
"""Records acpx's run of golden-acp.flow.mjs as golden-acp-acpx-0.19.3.json, which
FlowRunTests.theAcpBundleIsWrittenAsAcpxWritesIt compares SwiftACP's run with.

Usage: record-golden-acp.py <node> <acpx dist/cli.js>

The run is normalized as the test normalizes SwiftACP's (`FlowRunTests.acpGoldenFiles`):
the run's id, its random suffix (in session names), the runs and flow directories, times,
durations and UUIDs replaced; each artifact named, and each reference to it written, by
what it holds once normalized; and in each session's events, the two ways SwiftACP's own
messages differ from acpx's on the wire left out — their keys sorted, as SwiftACP sends
them (#64), its request ids counted from the first, and its `clientInfo`.
"""
import hashlib, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
ARTIFACT_REF = re.compile(
    r'\{\s*"path":\s*"artifacts/sha256-([0-9a-f]{64})(\.[a-z]+)",\s*"mediaType":\s*"([^"]*)",'
    r'\s*"bytes":\s*\d+,\s*"sha256":\s*"[0-9a-f]{64}"\s*\}')


def normalized(text, run_id, runs, flow_dir, bundle_ids=()):
    # A session's bundle id ends in a hash of its binding's key, which holds its directory.
    for bundle_id in bundle_ids:
        text = text.replace(bundle_id, bundle_id[:-8] + "<BUNDLE>")
    text = text.replace(run_id, "<RUNID>").replace(run_id[-8:], "<RUNSFX>")
    text = text.replace(runs, "<RUNS>").replace(flow_dir, "<FLOWDIR>")
    text = re.sub(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", "<TIME>", text)
    text = re.sub(r'"durationMs":( ?)\d+', r'"durationMs":\1<MS>', text)
    seen = {}
    return UUID.sub(lambda m: seen.setdefault(m.group(0), "<UUID%d>" % (len(seen) + 1)), text)


def sorted_keys(value):
    if isinstance(value, dict):
        return {key: sorted_keys(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [sorted_keys(item) for item in value]
    return value


def known_wire(text):
    events = [json.loads(line) for line in text.splitlines() if line.strip()]
    base = None
    for event in events:
        message = event.get("message")
        if event.get("direction") == "outbound" and isinstance(message, dict):
            message = sorted_keys(message)
            if isinstance(message.get("params"), dict) and "clientInfo" in message["params"]:
                message["params"]["clientInfo"] = "<CLIENT>"
            event["message"] = message
            if base is None and "method" in message and isinstance(message.get("id"), int):
                base = message["id"]
    for event in events:
        message = event.get("message")
        ours = isinstance(message, dict) and (("method" in message) == (event.get("direction") == "outbound"))
        if ours and base is not None and isinstance(message.get("id"), int) and not isinstance(message["id"], bool):
            message["id"] = "<ID+%d>" % (message["id"] - base)
    return "".join(json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n" for event in events)


def bundle_files(run_dir, run_id, runs, flow_dir):
    raw = {}
    for dirpath, _, names in os.walk(run_dir):
        for name in names:
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, run_dir)
            raw[relative] = (oct(os.stat(path).st_mode & 0o777), open(path, encoding="utf-8").read())
    bundle_ids = sorted({rel.split("/")[1] for rel in raw if rel.startswith("sessions/")})
    texts = {rel: normalized(text, run_id, runs, flow_dir, bundle_ids) for rel, (_, text) in raw.items()}
    canon = {}
    for rel, text in texts.items():
        if rel.startswith("artifacts/sha256-"):
            canon[rel[len("artifacts/sha256-"):].split(".")[0]] = hashlib.sha256(text.encode()).hexdigest()[:16]
    files = {}
    for rel, text in texts.items():
        text = ARTIFACT_REF.sub(lambda m: "<ARTIFACT %s%s %s>" % (canon[m.group(1)], m.group(2), m.group(3)), text)
        if rel.endswith("events.ndjson"):
            text = known_wire(text)
        mode = raw[rel][0]
        for sha, short in canon.items():
            rel = rel.replace("sha256-" + sha, short)
        for bundle_id in bundle_ids:
            rel = rel.replace(bundle_id, bundle_id[:-8] + "<BUNDLE>")
        files[rel] = {"mode": "0o" + mode[2:], "content": text}
    return files


def main():
    node, cli = sys.argv[1], sys.argv[2]
    home = tempfile.mkdtemp(prefix="golden-acp-home-")
    flow_dir = os.path.realpath(tempfile.mkdtemp(prefix="golden-acp-flow-"))
    try:
        shutil.copy(os.path.join(HERE, "golden-acp.flow.mjs"), flow_dir)
        shutil.copy(os.path.join(HERE, "..", "mock-agent.py"), flow_dir)
        os.mkdir(os.path.join(flow_dir, "sub"))
        with open(os.path.join(flow_dir, ".acpxrc.json"), "w") as config:
            json.dump({"agents": {"mock": {"command": "python3", "args": [os.path.join(flow_dir, "mock-agent.py")]}}},
                      config)
        args = ["--format", "json"]
        arguments = ["--input-json", '{"topic":"golden","dir":"sub"}']
        env = {"HOME": home, "PATH": os.path.dirname(node) + ":/usr/bin:/bin"}
        done = subprocess.run(
            [node, cli, "--cwd", flow_dir, *args, "flow", "run", os.path.join(flow_dir, "golden-acp.flow.mjs"),
             *arguments], cwd=flow_dir, env=env, capture_output=True, text=True, timeout=120)
        runs = os.path.join(home, ".acpx", "flows", "runs")
        run_id = os.listdir(runs)[0]
        version = subprocess.run([node, cli, "--version"], capture_output=True, text=True).stdout.strip()
        golden = {
            "acpx": version,
            "args": args + ["flow", "run", "golden-acp.flow.mjs"] + arguments,
            "exit": done.returncode,
            "stdout": normalized(done.stdout, run_id, runs, flow_dir),
            "stderr": normalized(done.stderr, run_id, runs, flow_dir),
            "files": bundle_files(os.path.join(runs, run_id), run_id, runs, flow_dir),
        }
        with open(os.path.join(HERE, "golden-acp-acpx-%s.json" % version), "w") as out:
            json.dump(golden, out, indent=2, ensure_ascii=False)
            out.write("\n")
        print("recorded acpx %s: exit %d, %d files" % (version, done.returncode, len(golden["files"])))
    finally:
        shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(flow_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
