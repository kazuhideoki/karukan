import contextlib
import io
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import run_comparison


class ComparisonArtifactTests(unittest.TestCase):
    def test_missing_log_replaces_previous_success_without_posting(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            output = root / "comparison-results.json"
            output.write_text('{"status":"comparisonCompleted","results":["stale"]}')
            with mock.patch.object(run_comparison.subprocess, "run") as send, contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["pid"])
            self.assertEqual(code, 2)
            result = json.loads(output.read_text())
            self.assertEqual(result["status"], "driverError")
            self.assertEqual(result["results"], [])
            self.assertTrue(result["error"])
            send.assert_not_called()

    def test_timeout_replaces_previous_success_without_posting(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "client-events.jsonl").write_text("")
            output = root / "comparison-results.json"
            output.write_text('{"status":"comparisonCompleted","results":["stale"]}')
            with mock.patch.object(run_comparison.subprocess, "run") as send, contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["hid"], arm_timeout=0)
            self.assertEqual(code, 2)
            self.assertEqual(json.loads(output.read_text())["status"], "driverTimedOut")
            self.assertEqual(json.loads(output.read_text())["results"], [])
            send.assert_not_called()

    def test_focus_rejection_stops_the_remaining_keys_and_saves_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            log = root / "client-events.jsonl"
            log.write_text("")

            def provide_trial(_delay):
                with log.open("a") as file:
                    for event in ["comparisonBegin", "trialReady"]:
                        file.write(json.dumps({"timestamp": run_comparison.time.time() * 1000,
                            "event": event, "run": "test-run", "trial": 1, "caseIndex": 0}) + "\n")

            with mock.patch.object(run_comparison.time, "sleep", side_effect=provide_trial), \
                mock.patch.object(run_comparison.subprocess, "run", side_effect=subprocess.CalledProcessError(2, ["guarded-key"])) as send, \
                contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["hid"], arm_timeout=1)
            self.assertEqual(code, 2)
            self.assertEqual(json.loads((root / "comparison-results.json").read_text())["status"], "driverError")
            self.assertEqual(send.call_count, 1)


if __name__ == "__main__":
    unittest.main()
