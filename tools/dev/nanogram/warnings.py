"""Warning baseline for upstream code (strictness A): counts per package from a build log, may only go down.

  tg warnings [--update] [--log FILE]

Counts unique `path:line:col: warning:` lines (xcodebuild repeats them) per package; our packages
(NanogramKit, packages/Nanogram*) are left out because they build with warnings as errors.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from nanogram import config

BASELINE = config.ROOT / "nanogram" / "warnings-baseline.json"

WARNING_RE = re.compile(r"^(?P<path>[^\s:][^:\n]*):\d+:\d+: warning: ", re.M)

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


def count(log: str, root: str | None = None) -> dict[str, int]:
    """Unique warning lines per package (`app` for app sources and paths outside the repo)."""
    root = str(config.ROOT) if root is None else root
    counts: dict[str, int] = {}
    seen: set[str] = set()
    for match in WARNING_RE.finditer(log):
        line_end = log.find("\n", match.start())
        line = log[match.start():line_end if line_end != -1 else len(log)].rstrip()
        if line in seen:
            continue
        seen.add(line)
        package = package_of(match.group("path"), root)
        if is_ours(package):
            continue
        counts[package] = counts.get(package, 0) + 1
    return dict(sorted(counts.items()))


def compare(baseline: dict, current: dict) -> list[str]:
    """Packages whose count went up (a package missing from the baseline counts as 0)."""
    return sorted(p for p, n in current.items() if n > baseline.get(p, 0))


def write_baseline(path: Path, counts: dict[str, int]) -> None:
    path.write_text(json.dumps(dict(sorted(counts.items())), indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg warnings", description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, required=True, help="log of a clean debug build")
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--root", default=str(config.ROOT), help="checkout the log was built from")
    parser.add_argument("--update", action="store_true", help="write the counts as the new baseline")
    args = parser.parse_args(argv)

    log = args.log.read_text(errors="replace")
    if "** BUILD SUCCEEDED **" not in log:
        print(f"warnings: {args.log} is not a successful build (no '** BUILD SUCCEEDED **')", file=sys.stderr)
        return 1
    current = count(log, root=args.root)
    total = sum(current.values())
    if args.update:
        write_baseline(args.baseline, current)
        print(f"warnings: baseline written to {args.baseline}: {total} warnings in {len(current)} packages")
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
    if increased:
        print(f"warnings: {len(increased)} package(s) have more warnings than nanogram/warnings-baseline.json; "
              "fix the new warnings (counts may only go down)", file=sys.stderr)
        return 1
    lower = sum(baseline.values()) - total
    hint = f"; {lower} fewer than the baseline, lock it in with: tools/dev/tg warnings --update" if lower > 0 else ""
    print(f"warnings: ok, {total} warnings, none above the baseline{hint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
