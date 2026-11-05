#!/usr/bin/env python3
"""perfgate: compare measured XCTest performance values with the baselines kept in the repository.

Xcode keeps performance baselines per machine in xcshareddata/xcbaselines, which neither Bazel nor `swift test`
reads, so ours are a JSON file (tools/dev/perf/baselines.json) keyed by machine model (`sysctl hw.model`).
Pure Python 3, no dependencies; nothing is built or run here. See docs/profiling.md, "Tests that measure".

Input (one or more, combined):
  --log FILE        output of `swift test`, `xcodebuild test` or a Bazel test.log: the
                    "Test Case '-[Class test]' measured [Time, seconds] average: ..." lines
  --xcresult PATH   a result bundle; read with `xcrun xcresulttool get test-results metrics`
  --json FILE       that tool's JSON output, or {"measurements": [{"test", "metric", "unit", "values"}]}

Commands:
  check     compare with the baselines (the default); exit 1 on a regression
  record    set the baseline of every measurement to this run (owner devices only)
  model     print the machine model that keys the baselines

Rules:
  - A measurement without a baseline is recorded (check) or skipped (not an owner device), never a failure.
  - Baselines are stored only for the owner's devices (owner_models in the baselines file): a CI box, another
    Mac or a colleague's phone is compared when it has a baseline and otherwise ignored.
  - All metrics are "smaller is better". A regression is more than --tolerance percent over the baseline average
    and also more than the absolute floor for the unit (so a 0.1 ms test cannot fail on noise).
"""

import argparse
import json
import os
import re
import subprocess
import sys

DEFAULT_TOLERANCE_PERCENT = 15.0
# Differences below this are noise whatever the percentage says.
ABSOLUTE_FLOOR = {"s": 0.0005, "ms": 0.5, "kB": 256.0, "kC": 500.0, "kI": 500.0}

LOG_LINE = re.compile(
    r"Test Case '-\[(?P<cls>[^\s\]]+) (?P<test>[^\s\]]+)\]' measured \[(?P<name>[^\]]+)\] "
    r"average: (?P<average>[-+0-9.eE]+).*?values: \[(?P<values>[^\]]*)\]"
    r"(?:, performanceMetricID:(?P<metric_id>[^\s,]+))?"
)


class GateError(Exception):
    pass


def hw_model(env=None, run=subprocess.run):
    """The machine model that keys the baselines: TG_PERF_MODEL, else sysctl hw.model."""
    env = os.environ if env is None else env
    if env.get("TG_PERF_MODEL"):
        return env["TG_PERF_MODEL"]
    try:
        result = run(["sysctl", "-n", "hw.model"], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise GateError("cannot read hw.model (%s); pass --model" % error)
    return result.stdout.strip()


def _unit(display_name):
    # "Time, seconds" -> "s", "Memory Peak Physical, kB" -> "kB", "CPU Instructions Retired, kI" -> "kI"
    if "," in display_name:
        unit = display_name.rsplit(",", 1)[1].strip()
        return {"seconds": "s"}.get(unit, unit)
    return ""


def parse_log(text, suite):
    """Measurements from XCTest log lines. A test measured twice in a log keeps the last run."""
    found = {}
    for line in text.splitlines():
        match = LOG_LINE.search(line)
        if not match:
            continue
        name = match.group("name")
        metric = match.group("metric_id") or name
        values = [float(v) for v in match.group("values").split(",") if v.strip()]
        if not values:
            values = [float(match.group("average"))]
        test = "%s.%s" % (match.group("cls"), match.group("test"))
        found[(suite, test, metric)] = {"unit": _unit(name), "values": values, "name": name}
    return found


def parse_json(data, suite):
    """Measurements from `xcresulttool get test-results metrics` output or the normalized layout."""
    found = {}
    if isinstance(data, dict) and "measurements" in data:
        for item in data["measurements"]:
            values = [float(v) for v in item["values"]]
            found[(item.get("suite", suite), item["test"], item["metric"])] = {
                "unit": item.get("unit", ""), "values": values, "name": item["metric"]}
        return found
    tests = data if isinstance(data, list) else data.get("tests", [])
    for test in tests:
        identifier = test.get("testIdentifier") or test.get("testIdentifierURL", "")
        for run in test.get("testRuns", []):
            for metric in run.get("metrics", []):
                values = [float(v) for v in metric.get("measurements", [])]
                if not values:
                    continue
                key = (suite, identifier, metric.get("identifier") or metric["displayName"])
                found[key] = {"unit": metric.get("unitOfMeasurement", ""), "values": values, "name": metric["displayName"]}
    return found


def read_xcresult(path, run=subprocess.run):
    try:
        result = run(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", path],
                     capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise GateError("cannot read %s with xcresulttool: %s" % (path, error))
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise GateError("xcresulttool printed no JSON for %s: %s" % (path, error))


def average(values):
    return sum(values) / len(values)


def key_text(key):
    return "/".join(key)


def load_baselines(path):
    if not os.path.exists(path):
        return {"version": 1, "owner_models": [], "baselines": {}}
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    data.setdefault("version", 1)
    data.setdefault("owner_models", [])
    data.setdefault("baselines", {})
    return data


def save_baselines(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def is_regression(measured, baseline, unit, tolerance):
    limit = baseline * (1.0 + tolerance / 100.0)
    return measured > limit and (measured - baseline) > ABSOLUTE_FLOOR.get(unit, 0.0)


def compare(measurements, baselines, model, tolerance, record_missing=True):
    """Returns (results, changed). Result statuses: ok, improved, regression, recorded, skipped.
    `baselines` is changed in place when a missing baseline is recorded on an owner device."""
    owner = model in baselines["owner_models"]
    stored = baselines["baselines"].setdefault(model, {}) if owner else baselines["baselines"].get(model, {})
    results = []
    changed = False
    for key in sorted(measurements):
        item = measurements[key]
        measured = average(item["values"])
        entry = stored.get(key_text(key))
        if entry is None:
            if owner and record_missing:
                stored[key_text(key)] = {"average": measured, "unit": item["unit"], "samples": len(item["values"])}
                changed = True
                results.append((key, "recorded", measured, None))
            else:
                results.append((key, "skipped", measured, None))
            continue
        baseline = entry["average"]
        unit = entry.get("unit", item["unit"])
        allowed = entry.get("tolerance_percent", tolerance)
        if is_regression(measured, baseline, unit, allowed):
            results.append((key, "regression", measured, baseline))
        elif baseline > 0 and measured < baseline * (1.0 - allowed / 100.0):
            results.append((key, "improved", measured, baseline))
        else:
            results.append((key, "ok", measured, baseline))
    return results, changed


def format_results(results, model):
    lines = ["perfgate on %s" % model]
    for key, status, measured, baseline in results:
        detail = "%.6g" % measured
        if baseline is not None:
            detail += " vs baseline %.6g (%+.1f%%)" % (baseline, (measured - baseline) / baseline * 100.0 if baseline else 0.0)
        lines.append("  %-10s %s  %s" % (status, key_text(key), detail))
    counts = {}
    for _, status, _, _ in results:
        counts[status] = counts.get(status, 0) + 1
    lines.append("  " + ", ".join("%d %s" % (counts[s], s) for s in sorted(counts)))
    return "\n".join(lines)


def gather(args, suite):
    measurements = {}
    for path in args.log:
        with open(path, encoding="utf-8", errors="replace") as handle:
            measurements.update(parse_log(handle.read(), suite))
    for path in args.json:
        with open(path, encoding="utf-8") as handle:
            measurements.update(parse_json(json.load(handle), suite))
    for path in args.xcresult:
        measurements.update(parse_json(read_xcresult(path), suite))
    return measurements


def default_baselines_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf", "baselines.json")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="check", choices=["check", "record", "model"])
    parser.add_argument("--log", action="append", default=[], metavar="FILE")
    parser.add_argument("--json", action="append", default=[], metavar="FILE")
    parser.add_argument("--xcresult", action="append", default=[], metavar="PATH")
    parser.add_argument("--suite", default="default", help="label that keeps the same test name of different test bundles apart")
    parser.add_argument("--baselines", default=default_baselines_path())
    parser.add_argument("--model", help="machine model (default: TG_PERF_MODEL, else sysctl hw.model)")
    parser.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE_PERCENT, help="allowed regression in percent")
    parser.add_argument("--no-record", action="store_true", help="check: do not record missing baselines")
    args = parser.parse_args(argv)

    try:
        model = args.model or hw_model()
        if args.command == "model":
            print(model)
            return 0
        measurements = gather(args, args.suite)
        if not measurements:
            raise GateError("no measurements found in the input (run the performance tests first; see docs/profiling.md)")
        baselines = load_baselines(args.baselines)
        if args.command == "record":
            if model not in baselines["owner_models"]:
                print("perfgate: %s is not an owner device (%s); nothing stored" % (model, ", ".join(baselines["owner_models"]) or "none"))
                return 0
            stored = baselines["baselines"].setdefault(model, {})
            for key, item in measurements.items():
                stored[key_text(key)] = {"average": average(item["values"]), "unit": item["unit"], "samples": len(item["values"])}
            save_baselines(args.baselines, baselines)
            print("perfgate: recorded %d baselines for %s" % (len(measurements), model))
            return 0
        results, changed = compare(measurements, baselines, model, args.tolerance, record_missing=not args.no_record)
        print(format_results(results, model))
        if changed:
            save_baselines(args.baselines, baselines)
            print("perfgate: new baselines written to %s (commit them)" % args.baselines)
        return 1 if any(status == "regression" for _, status, _, _ in results) else 0
    except GateError as error:
        print("perfgate: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
