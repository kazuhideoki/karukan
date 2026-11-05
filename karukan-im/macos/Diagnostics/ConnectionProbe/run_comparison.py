#!/usr/bin/env python3
"""Wait for the visible app's Run button, then type fixed test keys only.

Requires explicit user authorization, just like PhysicalKeyProbe. This driver
never activates an app, changes an input source, or starts a comparison itself.
"""
import json
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1]).resolve()
log = root / "client-events.jsonl"
driver = root / "PhysicalKeyProbe"
results = []
start = time.time() * 1000
offset = log.stat().st_size
handled = set()
deadline = time.monotonic() + 70
with log.open() as source:
    source.seek(offset)
    while time.monotonic() < deadline:
        line = source.readline()
        if not line:
            time.sleep(0.02)
            continue
        row = json.loads(line)
        if row["timestamp"] < start:
            continue
        if row["event"] == "trialReady":
            identity = (row["run"], row["trial"])
            if identity in handled:
                raise SystemExit("Duplicate trialReady; refusing further input")
            handled.add(identity)
            for key in ["k", "a", "return"]:
                posted = subprocess.run([str(driver), "key", key], check=True, capture_output=True, text=True)
                print(posted.stdout.strip(), flush=True)
        elif row["event"] == "trialResult":
            results.append(row)
            print(json.dumps({k: row[k] for k in ["trial", "condition", "length", "hasMarkedText", "matchesKa"]}), flush=True)
        elif row["event"] in ["comparisonAborted", "comparisonCompleted"]:
            output = {"status": row["event"], "start": start, "results": results}
            (root / "comparison-results.json").write_text(json.dumps(output, indent=2) + "\n")
            print(json.dumps({"status": row["event"], "trials": len(results),
                "exactKaCommits": sum(r["matchesKa"] and not r["hasMarkedText"] for r in results)}))
            raise SystemExit(0 if row["event"] == "comparisonCompleted" else 2)
raise SystemExit("Timed out; no further input will be sent")
