#!/usr/bin/env python3
"""Thin wrapper: the parity gate lives in the shared/ submodule (klaipher/nanogram-deps), one copy for all three apps.

The Mac reaches it through the core: submodules/telegram-ios/shared/parity.py. Runs it with this repository as --root
unless the caller passes one.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
TARGET = os.path.join(ROOT, "submodules", "telegram-ios", "shared", "parity.py")


def main(argv):
    if not os.path.isfile(TARGET):
        print(f"parity: {TARGET} is missing; run `git submodule update --init submodules/telegram-ios` and then "
              "`git -C submodules/telegram-ios submodule update --init shared`", file=sys.stderr)
        return 2
    args = list(argv)
    if args and "--root" not in args and args[0] in ("check", "fast", "roots", "push"):
        args = [args[0], "--root", ROOT] + args[1:]
    return subprocess.run([sys.executable, TARGET] + args).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
