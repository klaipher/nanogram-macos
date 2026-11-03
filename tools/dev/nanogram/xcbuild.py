"""The one xcodebuild invocation tg build uses.

Xcode reuses its cached build description only when the build request and the environment are the same as
last time; otherwise it spends 20–30 s (about 40 CPU s) recreating it. tg build therefore passes a fixed
argument set and an allow-listed environment, whatever shell it was started from.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

from nanogram import config

ENV_ALLOWLIST = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "DEVELOPER_DIR")
FIXED_PATH = f"{config.RUSTUP_BIN}:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DEFAULT_LANG = "en_US.UTF-8"
PACKAGE_FLAGS = ("-skipPackagePluginValidation", "-skipMacroValidation", "-disableAutomaticPackageResolution")
NO_RESOLVE = "-disableAutomaticPackageResolution"
WORKSPACE = "Telegram-Mac.xcworkspace"
DESTINATION = "platform=macOS,arch=arm64"
RECREATED_MARKER = "Build description signature:"
RESOLVE_ERROR = re.compile(r"Package\.resolved|resolved file", re.IGNORECASE)


def build_env(base: Mapping[str, str]) -> dict[str, str]:
    env = {name: base[name] for name in ENV_ALLOWLIST if name in base}
    env.setdefault("LANG", DEFAULT_LANG)
    env["PATH"] = FIXED_PATH
    return env


def xcodebuild_args(*, configuration: str, scheme: str, derived: Path, xcconfig: Path, conditions: str,
                    clean: bool, extra: Sequence[str], resolve: bool = False) -> list[str]:
    package_flags = [flag for flag in PACKAGE_FLAGS if not (flag == NO_RESOLVE and (clean or resolve))]
    return ["build", "-workspace", WORKSPACE, "-scheme", scheme, "-configuration", configuration,
            "-destination", DESTINATION, "-derivedDataPath", str(derived),
            "-xcconfig", str(xcconfig), f"SWIFT_ACTIVE_COMPILATION_CONDITIONS={conditions}",
            "COMPILER_INDEX_STORE_ENABLE=NO", "-showBuildTimingSummary", *package_flags, *extra]


def description_reused(log: str) -> bool:
    return RECREATED_MARKER not in log


def description_status(log: str) -> str | None:
    if "CreateBuildDescription" not in log:
        return None
    if description_reused(log):
        return "reused"
    return "recreated (costs 20–30 s; happens after setting or environment changes)"


def needs_resolve_hint(log: str) -> bool:
    return any(RESOLVE_ERROR.search(line) for line in log.splitlines() if "error" in line.lower())


def run(argv: list[str]) -> int:
    own, extra = (argv[:argv.index("--")], argv[argv.index("--") + 1:]) if "--" in argv else (argv, [])
    parser = argparse.ArgumentParser(prog="tg xcbuild run")
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--derived", type=Path, required=True)
    parser.add_argument("--xcconfig", type=Path, required=True)
    parser.add_argument("--conditions", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--resolve-packages", action="store_true")
    args = parser.parse_args(own)
    command = ["xcodebuild", *xcodebuild_args(configuration=args.configuration, scheme=args.scheme,
                                              derived=args.derived, xcconfig=args.xcconfig,
                                              conditions=args.conditions, clean=args.clean, extra=extra,
                                              resolve=args.resolve_packages)]
    with args.log.open("w") as log:
        status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=build_env(os.environ),
                                cwd=config.ROOT).returncode
    text = args.log.read_text(errors="replace")
    status_line = description_status(text)
    if status_line:
        print(f"build description: {status_line}")
    if status != 0 and needs_resolve_hint(text):
        print("hint: run tg build --clean to re-resolve packages", file=sys.stderr)
    return status


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] != "run":
        print("usage: python3 -m nanogram.xcbuild run --configuration … --scheme … --derived … --xcconfig … "
              "--conditions … --log … [--clean] [--resolve-packages] [-- extra xcodebuild args]", file=sys.stderr)
        return 2
    return run(argv[1:])


if __name__ == "__main__":
    sys.exit(main())
