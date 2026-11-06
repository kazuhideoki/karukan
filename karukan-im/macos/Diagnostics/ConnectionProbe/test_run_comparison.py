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
                            "event": event, "run": "test-run", "trial": 1, "caseIndex": 0,
                            "condition": "baseline"}) + "\n")

            with mock.patch.object(run_comparison.time, "sleep", side_effect=provide_trial), \
                mock.patch.object(run_comparison.subprocess, "run", side_effect=subprocess.CalledProcessError(2, ["guarded-key"])) as send, \
                contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["hid"], arm_timeout=1)
            self.assertEqual(code, 2)
            self.assertEqual(json.loads((root / "comparison-results.json").read_text())["status"], "driverError")
            self.assertEqual(send.call_count, 1)

    def test_unknown_condition_or_unsolicited_recovery_never_posts(self):
        for event, fields in [
            ("trialSourceSelectionRequested", {"condition": "unknown"}),
            ("trialReady", {"condition": "unknown"}),
            ("recoveryReady", {"phase": "unchanged"}),
        ]:
            with self.subTest(event=event), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                log = root / "client-events.jsonl"
                log.write_text("")

                def provide_phase(_delay):
                    with log.open("a") as file:
                        for name in ["comparisonBegin", event]:
                            file.write(json.dumps({"timestamp": run_comparison.time.time() * 1000,
                                "event": name, "run": "test-run", "trial": 1,
                                "caseIndex": 0, **fields}) + "\n")

                with mock.patch.object(run_comparison.time, "sleep", side_effect=provide_phase), \
                    mock.patch.object(run_comparison.subprocess, "run") as send, \
                    contextlib.redirect_stdout(io.StringIO()):
                    code = run_comparison.run(root, ["pid"], arm_timeout=1)
                self.assertEqual(code, 2)
                send.assert_not_called()

    def test_live_selector_is_stopped_after_the_field_rejects_a_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            log = root / "client-events.jsonl"
            log.write_text("")

            def provide_phases(_delay):
                with log.open("a") as file:
                    for event in ["comparisonBegin", "trialBegin", "trialSourceSelectionRequested", "trialReady"]:
                        file.write(json.dumps({"timestamp": run_comparison.time.time() * 1000,
                            "event": event, "run": "test-run", "trial": 1, "caseIndex": 0,
                            "condition": "primed-selector-alive"}) + "\n")

            child = mock.Mock()
            child.poll.return_value = None
            child.stdout = io.StringIO('{"status":0,"timing":"stay-alive"}\n')
            with mock.patch.object(run_comparison.time, "sleep", side_effect=provide_phases), \
                mock.patch.object(run_comparison.subprocess, "Popen", return_value=child), \
                mock.patch.object(run_comparison.select, "select", return_value=([child.stdout], [], [])), \
                mock.patch.object(run_comparison.subprocess, "run", side_effect=subprocess.CalledProcessError(2, ["guarded-key"])) as send, \
                contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["pid"], arm_timeout=1)
            self.assertEqual(code, 2)
            self.assertEqual(send.call_count, 1)
            child.terminate.assert_called_once()
            child.wait.assert_called_once_with(timeout=1)
            self.assertTrue(child.stdout.closed)
            self.assertEqual(json.loads((root / "comparison-results.json").read_text())["status"], "driverError")

    def test_manual_comparison_selects_source_but_never_calls_key_driver(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            log = root / "client-events.jsonl"
            log.write_text("")

            def provide_phases(_delay):
                with log.open("a") as file:
                    for event in ["comparisonBegin", "trialPrimeReady", "trialSourceSelectionRequested",
                                  "trialReady", "trialResult", "comparisonCompleted"]:
                        file.write(json.dumps({"timestamp": run_comparison.time.time() * 1000,
                            "event": event, "run": "manual-run", "trial": 1, "caseIndex": 0,
                            "condition": "primed", "manualKeys": True, "length": 1,
                            "matchesKa": True, "hasMarkedText": False}) + "\n")

            with mock.patch.object(run_comparison.time, "sleep", side_effect=provide_phases), \
                mock.patch.object(run_comparison.subprocess, "run", return_value=mock.Mock(stdout='{"status":0}')) as send, \
                mock.patch.object(run_comparison.subprocess, "Popen") as spawn, \
                contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["pid"], arm_timeout=1, require_manual=True)
            self.assertEqual(code, 0)
            self.assertEqual(send.call_count, 1)
            self.assertEqual(send.call_args.args[0], [str(root / "SelectProbeSource"), "Karukan", "immediate"])
            spawn.assert_not_called()
            result = json.loads((root / "comparison-results.json").read_text())
            self.assertTrue(result["manualKeys"])
            self.assertEqual(result["results"][0]["delivery"], "physical")

    def test_manual_only_driver_rejects_automatic_suite_without_mutations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            log = root / "client-events.jsonl"
            log.write_text("")

            def provide_begin(_delay):
                with log.open("a") as file:
                    file.write(json.dumps({"timestamp": run_comparison.time.time() * 1000,
                        "event": "comparisonBegin", "run": "automatic-run", "manualKeys": False}) + "\n")

            with mock.patch.object(run_comparison.time, "sleep", side_effect=provide_begin), \
                mock.patch.object(run_comparison.subprocess, "run") as send, \
                mock.patch.object(run_comparison.subprocess, "Popen") as spawn, \
                contextlib.redirect_stdout(io.StringIO()):
                code = run_comparison.run(root, ["pid"], arm_timeout=1, require_manual=True)
            self.assertEqual(code, 2)
            send.assert_not_called()
            spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
