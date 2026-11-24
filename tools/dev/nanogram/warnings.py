"""Warning baseline for upstream code (strictness A): counts per package from a build log, may only go down.

  tg warnings [--update] [--log FILE]

Counts unique `path:line:col: warning:` lines (xcodebuild repeats them) per package; our packages
(NanogramKit, packages/Nanogram*) are left out because they build with warnings as errors. Deprecated and
obsoleted API uses get their own per-package baseline, so a new one fails even when the package total stays.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

from nanogram import config

BASELINE = config.ROOT / "nanogram" / "warnings-baseline.json"
DEPRECATIONS = config.ROOT / "nanogram" / "deprecations-baseline.json"

WARNING_RE = re.compile(r"^(?P<path>[^\s:][^:\n]*):\d+:\d+: warning: ", re.M)
DEPRECATION_RE = re.compile(r"\b(?:is|was) (?:deprecated|obsoleted)\b")

# Most specific first: telegram-ios is itself under submodules/.
PACKAGE_RES = (
    re.compile(r"^submodules/telegram-ios/(?:submodules|third-party)/([^/]+)/"),
    re.compile(r"^packages/([^/]+)/"),
    re.compile(r"^submodules/([^/]+)/"),
)


def is_ours(package: str) -> bool:
    return package.startswith("Nanogram")


def package_of(path: str, root: str) -> str:
    prefix = root.rstrip("/") + "/"
    if path.startswith(prefix):
        relative = path[len(prefix):]
        for pattern in PACKAGE_RES:
            match = pattern.match(relative)
            if match:
                return match.group(1)
    return "app"


def is_cut_path(path: str, root: str) -> bool:
    """A path whose start was cut off by interleaved xcodebuild output (`ces/StarsUI/A.swift`, `/EntertainmentUI/A.swift`).

    Such a fragment is outside the repo, so it would land in `app` and make that count wobble. Real paths outside the repo
    (SDK headers, DerivedData) are absolute and start with a top-level directory that exists.
    """
    if path.startswith(root.rstrip("/") + "/"):
        return False
    if not path.startswith("/"):
        return True
    top = path.split("/")[1]
    return not os.path.isdir("/" + top)


def count(log: str, root: str | None = None, only=None) -> dict[str, int]:
    """Unique warning lines per package (`app` for app sources and paths outside the repo).

    xcodebuild interleaves its output, which can cut a repeated warning line short; a line that is the start of another
    line at the same position is that cut copy, not a second warning.
    """
    root = str(config.ROOT) if root is None else root
    by_position: dict[str, tuple[str, set[str]]] = {}
    for match in WARNING_RE.finditer(log):
        line_end = log.find("\n", match.start())
        line = log[match.start():line_end if line_end != -1 else len(log)].rstrip()
        position = log[match.start():match.end()]
        by_position.setdefault(position, (match.group("path"), set()))[1].add(line)
    counts: dict[str, int] = {}
    for path, lines in by_position.values():
        if is_cut_path(path, root):
            continue
        package = package_of(path, root)
        if is_ours(package):
            continue
        whole = [line for line in lines if not any(other != line and other.startswith(line) for other in lines)]
        if only is not None:
            whole = [line for line in whole if only.search(line)]
        if whole:
            counts[package] = counts.get(package, 0) + len(whole)
    return dict(sorted(counts.items()))


def count_deprecations(log: str, root: str | None = None) -> dict[str, int]:
    """Unique deprecated/obsoleted API warnings per package."""
    return count(log, root=root, only=DEPRECATION_RE)


def compare(baseline: dict, current: dict) -> list[str]:
    """Packages whose count went up (a package missing from the baseline counts as 0)."""
    return sorted(p for p, n in current.items() if n > baseline.get(p, 0))


def write_baseline(path: Path, counts: dict[str, int]) -> None:
    path.write_text(json.dumps(dict(sorted(counts.items())), indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg warnings", description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, required=True, help="log of a clean debug build")
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--deprecations", type=Path, default=DEPRECATIONS)
    parser.add_argument("--root", default=str(config.ROOT), help="checkout the log was built from")
    parser.add_argument("--update", action="store_true", help="write the counts as the new baseline")
    args = parser.parse_args(argv)

    log = args.log.read_text(errors="replace")
    if "** BUILD SUCCEEDED **" not in log:
        print(f"warnings: {args.log} is not a successful build (no '** BUILD SUCCEEDED **')", file=sys.stderr)
        return 1
    current = count(log, root=args.root)
    deprecations = count_deprecations(log, root=args.root)
    total = sum(current.values())
    if args.update:
        write_baseline(args.baseline, current)
        write_baseline(args.deprecations, deprecations)
        print(f"warnings: baseline written to {args.baseline}: {total} warnings in {len(current)} packages, "
              f"{sum(deprecations.values())} of them deprecations")
        return 0
    if not args.baseline.is_file():
        print(f"warnings: no baseline at {args.baseline}; create it with: tools/dev/tg warnings --update",
              file=sys.stderr)
        return 1
    baseline = json.loads(args.baseline.read_text())
    increased = compare(baseline, current)
    for package in sorted(set(baseline) | set(current)):
        before, after = baseline.get(package, 0), current.get(package, 0)
        if before != after and package not in increased:
            print(f"warnings: {package}: {before} -> {after}")
    for package in increased:
        print(f"warnings: {package}: {baseline.get(package, 0)} -> {current[package]} (more than the baseline)",
              file=sys.stderr)
    deprecations_increased: list[str] = []
    if args.deprecations.is_file():
        deprecation_baseline = json.loads(args.deprecations.read_text())
        deprecations_increased = compare(deprecation_baseline, deprecations)
        for package in deprecations_increased:
            print(f"warnings: {package}: {deprecation_baseline.get(package, 0)} -> {deprecations[package]} deprecation "
                  "warnings (more than the baseline)", file=sys.stderr)
    else:
        print(f"warnings: no deprecation baseline at {args.deprecations}; create it with: tools/dev/tg warnings --update")
    if increased or deprecations_increased:
        print(f"warnings: {len(set(increased) | set(deprecations_increased))} package(s) have more warnings than the "
              "baseline; fix the new warnings (counts may only go down)", file=sys.stderr)
        return 1
    lower = sum(baseline.values()) - total
    hint = f"; {lower} fewer than the baseline, lock it in with: tools/dev/tg warnings --update" if lower > 0 else ""
    print(f"warnings: ok, {total} warnings, none above the baseline{hint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
