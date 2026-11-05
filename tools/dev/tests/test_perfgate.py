import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import perfgate  # noqa: E402

LOG = """\
Test Suite 'PostboxPerformanceTests' started
/x/PostboxPerformanceTests.swift:40: Test Case '-[PostboxTests.PostboxPerformanceTests testFetch]' measured [Time, seconds] average: 0.010, relative standard deviation: 4.1%, values: [0.011000, 0.009000, 0.010000], performanceMetricID:com.apple.XCTPerformanceMetric_WallClockTime, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%
/x/PostboxPerformanceTests.swift:40: Test Case '-[PostboxTests.PostboxPerformanceTests testFetch]' measured [Memory Peak Physical, kB] average: 1000.000, relative standard deviation: 1.0%, values: [990.0, 1010.0], performanceMetricID:com.apple.XCTPerformanceMetric_PhysicalMemory, baselineName: ""
Test Case '-[PostboxTests.PostboxPerformanceTests testFetch]' passed (1.2 seconds).
"""

OWNER = "Mac16,1"


def baselines(owner=(OWNER,), stored=None):
    return {"version": 1, "owner_models": list(owner), "baselines": stored or {}}


class ParseTests(unittest.TestCase):
    def test_log_lines(self):
        found = perfgate.parse_log(LOG, "mac")
        self.assertEqual(len(found), 2)
        key = ("mac", "PostboxTests.PostboxPerformanceTests.testFetch", "com.apple.XCTPerformanceMetric_WallClockTime")
        self.assertEqual(found[key]["values"], [0.011, 0.009, 0.010])
        self.assertEqual(found[key]["unit"], "s")
        memory = ("mac", "PostboxTests.PostboxPerformanceTests.testFetch", "com.apple.XCTPerformanceMetric_PhysicalMemory")
        self.assertEqual(found[memory]["unit"], "kB")

    def test_log_without_measurements(self):
        self.assertEqual(perfgate.parse_log("Test Case '-[A b]' passed (0.1 seconds).", "s"), {})

    def test_xcresulttool_json(self):
        data = [{"testIdentifier": "Suite/testA()", "testRuns": [{"metrics": [
            {"displayName": "Clock Monotonic Time", "unitOfMeasurement": "s", "measurements": [0.2, 0.4],
             "identifier": "com.apple.dt.XCTMetric_Clock.time.monotonic"},
            {"displayName": "Empty", "unitOfMeasurement": "s", "measurements": []}]}]}]
        found = perfgate.parse_json(data, "ios")
        self.assertEqual(list(found), [("ios", "Suite/testA()", "com.apple.dt.XCTMetric_Clock.time.monotonic")])

    def test_normalized_json(self):
        data = {"measurements": [{"test": "T.t", "metric": "wall", "unit": "s", "values": [1, 3]}]}
        found = perfgate.parse_json(data, "s")
        self.assertEqual(perfgate.average(found[("s", "T.t", "wall")]["values"]), 2.0)


class CompareTests(unittest.TestCase):
    def measurement(self, values, unit="s"):
        return {("s", "T.t", "wall"): {"unit": unit, "values": values, "name": "wall"}}

    def test_missing_baseline_on_owner_is_recorded_not_failed(self):
        data = baselines()
        results, changed = perfgate.compare(self.measurement([1.0]), data, OWNER, 15)
        self.assertEqual(results[0][1], "recorded")
        self.assertTrue(changed)
        self.assertEqual(data["baselines"][OWNER]["s/T.t/wall"]["average"], 1.0)

    def test_missing_baseline_elsewhere_is_skipped_and_not_stored(self):
        data = baselines()
        results, changed = perfgate.compare(self.measurement([1.0]), data, "Mac15,3", 15)
        self.assertEqual(results[0][1], "skipped")
        self.assertFalse(changed)
        self.assertNotIn("Mac15,3", data["baselines"])

    def test_no_record_flag(self):
        data = baselines()
        results, changed = perfgate.compare(self.measurement([1.0]), data, OWNER, 15, record_missing=False)
        self.assertEqual(results[0][1], "skipped")
        self.assertFalse(changed)

    def stored(self):
        return baselines(stored={OWNER: {"s/T.t/wall": {"average": 1.0, "unit": "s", "samples": 5}}})

    def test_within_tolerance_is_ok(self):
        results, _ = perfgate.compare(self.measurement([1.1]), self.stored(), OWNER, 15)
        self.assertEqual(results[0][1], "ok")

    def test_regression(self):
        results, _ = perfgate.compare(self.measurement([1.3]), self.stored(), OWNER, 15)
        self.assertEqual(results[0][1], "regression")

    def test_improvement(self):
        results, _ = perfgate.compare(self.measurement([0.5]), self.stored(), OWNER, 15)
        self.assertEqual(results[0][1], "improved")

    def test_tiny_absolute_difference_is_noise(self):
        data = baselines(stored={OWNER: {"s/T.t/wall": {"average": 0.0001, "unit": "s", "samples": 5}}})
        results, _ = perfgate.compare(self.measurement([0.0002]), data, OWNER, 15)
        self.assertEqual(results[0][1], "ok")

    def test_per_entry_tolerance(self):
        data = self.stored()
        data["baselines"][OWNER]["s/T.t/wall"]["tolerance_percent"] = 50
        results, _ = perfgate.compare(self.measurement([1.3]), data, OWNER, 15)
        self.assertEqual(results[0][1], "ok")

    def test_non_owner_with_baseline_is_still_compared(self):
        data = baselines(stored={"Mac15,3": {"s/T.t/wall": {"average": 1.0, "unit": "s", "samples": 5}}})
        results, _ = perfgate.compare(self.measurement([2.0]), data, "Mac15,3", 15)
        self.assertEqual(results[0][1], "regression")


class MainTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.log = os.path.join(self.dir.name, "t.log")
        with open(self.log, "w") as handle:
            handle.write(LOG)
        self.baselines = os.path.join(self.dir.name, "baselines.json")
        with open(self.baselines, "w") as handle:
            json.dump(baselines(), handle)

    def run_main(self, *args):
        return perfgate.main(list(args) + ["--baselines", self.baselines, "--log", self.log, "--suite", "mac"])

    def test_first_run_records_second_run_passes_then_regression_fails(self):
        self.assertEqual(self.run_main("check", "--model", OWNER), 0)
        with open(self.baselines) as handle:
            stored = json.load(handle)["baselines"][OWNER]
        self.assertEqual(len(stored), 2)
        self.assertEqual(self.run_main("check", "--model", OWNER), 0)
        for entry in stored.values():
            entry["average"] = entry["average"] / 2.0
        data = baselines(stored={OWNER: stored})
        with open(self.baselines, "w") as handle:
            json.dump(data, handle)
        self.assertEqual(self.run_main("check", "--model", OWNER), 1)

    def test_other_machine_never_writes(self):
        self.assertEqual(self.run_main("check", "--model", "Mac15,3"), 0)
        self.assertEqual(self.run_main("record", "--model", "Mac15,3"), 0)
        with open(self.baselines) as handle:
            self.assertEqual(json.load(handle)["baselines"], {})

    def test_record_on_owner(self):
        self.assertEqual(self.run_main("record", "--model", OWNER), 0)
        with open(self.baselines) as handle:
            self.assertEqual(len(json.load(handle)["baselines"][OWNER]), 2)

    def test_no_measurements_is_a_usage_error(self):
        empty = os.path.join(self.dir.name, "empty.log")
        open(empty, "w").close()
        self.assertEqual(perfgate.main(["check", "--model", OWNER, "--baselines", self.baselines, "--log", empty]), 2)

    def test_model_comes_from_sysctl_or_override(self):
        self.assertEqual(perfgate.hw_model(env={"TG_PERF_MODEL": "X1"}), "X1")

        class Result:
            stdout = "Mac16,1\n"
        self.assertEqual(perfgate.hw_model(env={}, run=lambda *a, **k: Result()), "Mac16,1")

    def test_shipped_baselines_file_lists_the_owner_devices(self):
        shipped = perfgate.load_baselines(perfgate.default_baselines_path())
        self.assertEqual(sorted(shipped["owner_models"]), ["Mac16,1", "iPhone18,2"])
        self.assertEqual(shipped["version"], 1)


if __name__ == "__main__":
    unittest.main()
