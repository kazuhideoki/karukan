#!/usr/bin/env python3
"""Drive fixed keys in the disposable field after its visible Run button.

Requires explicit user authorization. Never activates an app or starts a trial.
The primed-source condition selects Karukan using a separate guarded process,
only when the foreground test field has requested that phase.
"""
import json
import pathlib
import subprocess
import sys
import time


def run(root, delivery_cycle, arm_timeout=20, run_timeout=90):
    log = root / "client-events.jsonl"
    driver = root / "PhysicalKeyProbe"
    deliveries, handled, results = {}, set(), []
    start = time.time() * 1000
    deadline = time.monotonic() + arm_timeout
    status, error, active_run = "waitingForStart", None, None
    output_path = root / "comparison-results.json"

    def save():
        output_path.write_text(json.dumps({"status": status, "start": start,
            "results": results, "error": error}, indent=2) + "\n")

    def post(row, phase, keys):
        identity = (row["run"], row["trial"], phase)
        if identity in handled:
            raise RuntimeError("Duplicate trial phase; refusing further input")
        handled.add(identity)
        delivery = delivery_cycle[row["caseIndex"] % len(delivery_cycle)]
        deliveries[row["trial"]] = delivery
        for key in keys:
            posted = subprocess.run([str(driver), "key", key, delivery], check=True,
                capture_output=True, text=True)
            print(posted.stdout.strip(), flush=True)

    save()  # A failed new run must never leave a previous success artifact.
    try:
        offset = log.stat().st_size
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
                if active_run is not None and row["run"] != active_run:
                    continue
                if row["event"] == "comparisonBegin":
                    if status != "waitingForStart":
                        raise RuntimeError("A second comparison started; refusing further input")
                    status = "running"
                    active_run = row["run"]
                    deadline = time.monotonic() + run_timeout
                elif status != "running":
                    continue
                elif row["event"] == "trialPrimeReady":
                    post(row, "prime", ["a"])
                elif row["event"] == "trialSourceSelectionRequested":
                    identity = (row["run"], row["trial"], "source")
                    if identity in handled:
                        raise RuntimeError("Duplicate source phase")
                    handled.add(identity)
                    subprocess.run([str(root / "SelectProbeSource"), "Karukan"], check=True)
                elif row["event"] == "trialReady":
                    post(row, "compose", ["k", "a", "return"])
                elif row["event"] == "trialResult":
                    row["delivery"] = deliveries[row["trial"]]
                    results.append(row)
                    save()
                    print(json.dumps({k: row[k] for k in ["trial", "condition", "delivery",
                        "length", "hasMarkedText", "matchesKa"]}), flush=True)
                elif row["event"] in ["comparisonAborted", "comparisonCompleted", "comparisonSuspendedOnFailure"]:
                    status = row["event"]
                    break
            else:
                status = "driverTimedOut"
    except KeyboardInterrupt:
        status = "driverInterrupted"
    except Exception as problem:
        status = "driverError"
        error = str(problem)
    finally:
        save()
    print(json.dumps({"status": status, "trials": len(results), "error": error,
        "exactKaCommits": sum(r["matchesKa"] and not r["hasMarkedText"] for r in results)}), flush=True)
    return 0 if status == "comparisonCompleted" else 2


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1]).resolve()
    delivery_cycle = sys.argv[2].split(",") if len(sys.argv) > 2 else ["pid"]
    if not delivery_cycle or any(mode not in ["hid", "session", "annotated", "pid"] for mode in delivery_cycle):
        raise SystemExit("Delivery cycle must use hid, session, annotated, or pid")
    raise SystemExit(run(root, delivery_cycle))
