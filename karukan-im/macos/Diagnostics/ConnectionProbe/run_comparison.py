#!/usr/bin/env python3
"""Drive fixed keys in the disposable field after its visible Run button.

Requires explicit user authorization. Never activates an app or starts a trial.
The primed-source condition selects Karukan using a separate guarded process,
only when the foreground test field has requested that phase.
"""
import argparse
import json
import pathlib
import select
import subprocess
import time

SOURCE_TIMINGS = {
    "apple-primed": "immediate",
    "apple-primed-alive": "stay-alive",
    "primed": "immediate",
    "primed-post-delay": "immediate",
    "primed-selector-hold": "hold-after",
    "primed-selector-pump": "pump-after",
    "primed-selector-alive": "stay-alive",
    "primed-pre-delay": "settle-before",
    "primed-in-process": None,
}
RECOVERY_PHASES = ["unchanged", "after-context-snapshot", "after-context-reconnect"]


def run(root, delivery_cycle, arm_timeout=20, run_timeout=180, require_manual=False):
    log = root / "client-events.jsonl"
    driver = root / "PhysicalKeyProbe"
    deliveries, handled, results = {}, set(), []
    source_results, recoveries, failed_trials = [], [], set()
    start = time.time() * 1000
    deadline = time.monotonic() + arm_timeout
    status, error, active_run = "waitingForStart", None, None
    output_path = root / "comparison-results.json"
    live_selector = None
    manual_keys = False

    def stop_selector():
        nonlocal live_selector
        if live_selector is not None:
            if live_selector.poll() is None:
                live_selector.terminate()
                try:
                    live_selector.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    live_selector.kill()
                    live_selector.wait(timeout=1)
            if live_selector.stdout is not None:
                live_selector.stdout.close()
            live_selector = None

    def save():
        output_path.write_text(json.dumps({"status": status, "start": start,
            "results": results, "sourceResults": source_results,
            "recoveries": recoveries, "error": error, "manualKeys": manual_keys,
            "requireManual": require_manual}, indent=2) + "\n")

    def post(row, phase, keys):
        identity = (row["run"], row["trial"], phase)
        if identity in handled:
            raise RuntimeError("Duplicate trial phase; refusing further input")
        handled.add(identity)
        delivery = "physical" if manual_keys else delivery_cycle[row["caseIndex"] % len(delivery_cycle)]
        deliveries[row["trial"]] = delivery
        if manual_keys:
            print(json.dumps({"event": "waitingForPhysicalKeys", "trial": row["trial"], "phase": phase}), flush=True)
            return
        for key in keys:
            if live_selector is not None and live_selector.poll() is not None:
                raise RuntimeError("Persistent selector stopped before input; refusing further keys")
            posted = subprocess.run([str(driver), "key", key, delivery], check=True,
                capture_output=True, text=True, timeout=5)
            metadata = json.loads(posted.stdout)
            metadata["liveSelectorPID"] = live_selector.pid if live_selector is not None else None
            print(json.dumps(metadata), flush=True)

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
                    manual_keys = row.get("manualKeys") is True
                    if require_manual and not manual_keys:
                        raise RuntimeError("Manual-only driver rejected an automatic comparison")
                    status = "running"
                    active_run = row["run"]
                    deadline = time.monotonic() + run_timeout
                elif status != "running":
                    continue
                elif row["event"] == "trialBegin":
                    stop_selector()
                elif row["event"] == "trialPrimeReady":
                    if row.get("condition") not in SOURCE_TIMINGS:
                        raise RuntimeError("Unknown primed condition; refusing input")
                    post(row, "prime", ["a"])
                elif row["event"] == "trialSourceSelectionRequested":
                    identity = (row["run"], row["trial"], "source")
                    if identity in handled:
                        raise RuntimeError("Duplicate source phase")
                    handled.add(identity)
                    if row.get("condition") not in SOURCE_TIMINGS:
                        raise RuntimeError("Unknown source condition; refusing selection")
                    timing = SOURCE_TIMINGS[row["condition"]]
                    if timing is not None:
                        target_source = "AppleJapanese" if row["condition"].startswith("apple-") else "Karukan"
                        command = [str(root / "SelectProbeSource"), target_source, timing]
                        if timing == "stay-alive":
                            if live_selector is not None:
                                raise RuntimeError("A selector is already running")
                            live_selector = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
                            if not select.select([live_selector.stdout], [], [], 5)[0]:
                                raise RuntimeError("Persistent selector did not report readiness")
                            selection_output = live_selector.stdout.readline()
                            if live_selector.poll() is not None:
                                raise RuntimeError("Persistent selector exited before readiness")
                        else:
                            selection = subprocess.run(command, check=True, capture_output=True, text=True, timeout=5)
                            selection_output = selection.stdout
                        source_results.append({"trial": row["trial"], "condition": row["condition"],
                            **json.loads(selection_output)})
                        save()
                elif row["event"] == "trialReady":
                    if row.get("condition") not in ["baseline", "keep", "before", "after", "rapid", *SOURCE_TIMINGS]:
                        raise RuntimeError("Unknown trial condition; refusing input")
                    if row["condition"] == "primed-post-delay":
                        time.sleep(0.6)
                    post(row, "compose", ["k", "a", "return"])
                elif row["event"] == "trialResult":
                    row["delivery"] = deliveries[row["trial"]]
                    results.append(row)
                    if not row["matchesKa"] or row["hasMarkedText"]:
                        failed_trials.add((row["run"], row["trial"]))
                    save()
                    print(json.dumps({k: row[k] for k in ["trial", "condition", "delivery",
                        "length", "hasMarkedText", "matchesKa"]}), flush=True)
                elif row["event"] == "recoveryReady":
                    if (row["run"], row["trial"]) not in failed_trials or row.get("phase") not in RECOVERY_PHASES:
                        raise RuntimeError("Unrequested recovery phase; refusing input")
                    post(row, "recovery-" + row["phase"], ["k", "a", "return"])
                elif row["event"] == "recoveryResult":
                    row["delivery"] = deliveries[row["trial"]]
                    recoveries.append(row)
                    save()
                    print(json.dumps({k: row[k] for k in ["trial", "phase", "lengthDelta",
                        "markedWrites", "committedKa"]}), flush=True)
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
        try:
            stop_selector()
        except Exception as problem:
            status = "driverError"
            error = f"{error or ''} Selector cleanup failed: {problem}".strip()
        finally:
            save()
    print(json.dumps({"status": status, "trials": len(results), "error": error,
        "exactKaCommits": sum(r["matchesKa"] and not r["hasMarkedText"] for r in results)}), flush=True)
    return 0 if status == "comparisonCompleted" else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("delivery_cycle", nargs="?", default="pid")
    parser.add_argument("--manual-keys-only", action="store_true", help="Never synthesize keys; accept only a manual comparison")
    args = parser.parse_args()
    root = args.root.resolve()
    delivery_cycle = args.delivery_cycle.split(",")
    if not delivery_cycle or any(mode not in ["hid", "session", "annotated", "pid"] for mode in delivery_cycle):
        raise SystemExit("Delivery cycle must use hid, session, annotated, or pid")
    raise SystemExit(run(root, delivery_cycle, arm_timeout=600 if args.manual_keys_only else 20,
        run_timeout=300 if args.manual_keys_only else 180,
        require_manual=args.manual_keys_only))
