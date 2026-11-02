"""`tg frameworks`: builds the native libraries with our settings (arm64, macOS 15) and checks the result.

Upstream's scripts/configure_frameworks.sh does the work and keeps its per-library stamps; we run it with
our xcconfig and verify that every required output exists and holds an arm64 slice only.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

from . import config

XCCONFIG = config.ROOT / "nanogram" / "Nanogram.xcconfig"
SCRIPTS = config.ROOT / "scripts"
EXPORTED_SETTINGS = ("MACOSX_DEPLOYMENT_TARGET", "ARCHS")
SETTING_RE = re.compile(r"^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*(//.*)?$")


def xcconfig_settings(path: Path) -> dict[str, str]:
    """Unconditional `KEY = value` settings of one xcconfig file (no includes, no [config=...] variants)."""
    settings = {}
    for line in Path(path).read_text().splitlines():
        match = SETTING_RE.match(line)
        if match:
            settings[match.group(1)] = match.group(2)
    return settings


def libraries() -> list[str]:
    text = (SCRIPTS / "configure_frameworks.sh").read_text()
    match = re.search(r"^declare -a libs=\(([^)]*)\)", text, re.MULTILINE)
    if not match:
        raise config.ConfigError("scripts/configure_frameworks.sh has no `declare -a libs=(...)` list any more: update frameworks.py")
    return re.findall(r'"([^"]+)"', match.group(1))


def required_outputs(root: Path | None = None) -> list[Path]:
    """Every output upstream's framework_required_outputs lists for `root`, plus tlottie's library."""
    root = Path(root or config.ROOT)
    script = (f'. "{SCRIPTS / "framework-inputs.sh"}"; '
              f'for lib in {" ".join(libraries())}; do framework_required_outputs "$1" "$lib" || exit 1; done')
    out = subprocess.run(["bash", "-c", script, "bash", str(root)], capture_output=True, text=True, check=True).stdout
    paths = [Path(line) for line in out.splitlines() if line.strip()]
    paths.append(root / "core-xprojects" / "tlottie" / "build" / "libtlottie.a")
    return paths


def lipo_archs(path: Path) -> list[str]:
    result = subprocess.run(["lipo", "-archs", str(path)], capture_output=True, text=True, check=False)
    return result.stdout.split() if result.returncode == 0 else [f"unreadable ({result.stderr.strip()})"]


def verify_outputs(root: Path | None = None, archs_of: Callable[[Path], list[str]] = lipo_archs) -> list[str]:
    root = Path(root or config.ROOT)
    problems = []
    for path in required_outputs(root):
        shown = path.relative_to(root) if path.is_relative_to(root) else path
        if not path.is_file() or path.stat().st_size == 0:
            problems.append(f"missing {shown}")
            continue
        if path.suffix == ".a":
            archs = archs_of(path)
            if archs != ["arm64"]:
                problems.append(f"{shown}: architectures {' '.join(archs)} (want arm64)")
    return problems


def build_environment(timing_log: Path, base: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if base is None else base)
    settings = xcconfig_settings(XCCONFIG)
    for key in EXPORTED_SETTINGS:
        env[key] = settings[key]
    env["XCODE_XCCONFIG_FILE"] = str(XCCONFIG)
    env["CMAKE_POLICY_VERSION_MINIMUM"] = "3.5"
    env["BUILD_TIMING_LOG"] = str(timing_log)
    env["PATH"] = f"{config.RUSTUP_BIN}:{env.get('PATH', '/usr/bin:/bin')}"
    return env


def build_frameworks(timing_log: Path, log: Path) -> None:
    timing_log.parent.mkdir(parents=True, exist_ok=True)
    timing_log.write_text("")
    with log.open("w") as handle:
        result = subprocess.run(["sh", str(SCRIPTS / "configure_frameworks.sh")], cwd=config.ROOT,
                                env=build_environment(timing_log), stdout=handle, stderr=subprocess.STDOUT, check=False)
    if result.returncode != 0:
        raise config.ConfigError(f"native libraries failed to build (exit {result.returncode}): see {log}")


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    timing_log = config.BUILD_OUTPUT / "frameworks-timing.tsv"
    log = config.BUILD_OUTPUT / "frameworks.log"
    if "--verify-only" not in argv:
        print(f"==> Building native libraries (arm64), log: {log.relative_to(config.ROOT)}", flush=True)
        started = time.monotonic()
        try:
            build_frameworks(timing_log, log)
        except config.ConfigError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        for line in timing_log.read_text().splitlines():
            print("   " + line.replace("\t", "  "))
        print(f"==> Native libraries done in {round(time.monotonic() - started)}s")
    problems = verify_outputs()
    for problem in problems:
        print(f"frameworks: {problem}", file=sys.stderr)
    if not problems:
        print("frameworks: all outputs present, arm64 only")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
