"""Keeps one Nanogram in Spotlight and Launchpad. Every build, archive, export, mounted disk image and launched copy
registers itself with LaunchServices, and Spotlight lists each one. This unregisters every Nanogram.app except the
installed one (/Applications/Nanogram.app, or the newest copy when nothing is installed). Files are never touched;
`lsregister -f <path>` registers a copy again.

    python3 -m nanogram.appregistry [--dry-run]
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/"
              "lsregister")
INSTALLED = Path("/Applications/Nanogram.app")
IDENTIFIER = "org.klaipher.Nanogram"
APP_NAME = "Nanogram.app"
DISPLAY_NAME = "Nanogram"
LEFT_ALONE_MARKERS = ("/Daemon Containers/", "/Placeholders-v", "/.config/telegram-ios/")


@dataclass(frozen=True)
class Registration:
    path: Path
    identifier: str
    name: str


def parse_dump(text: str) -> list[Registration]:
    records: list[Registration] = []
    fields: dict[str, str] = {}

    def flush():
        if "path" in fields:
            records.append(Registration(Path(fields["path"]), fields.get("identifier", ""), fields.get("name", "")))
        fields.clear()

    for line in text.splitlines():
        if line.startswith("-----"):
            flush()
            continue
        key, separator, value = line.partition(":")
        if not separator or key not in ("path", "identifier", "name") or key in fields:
            continue
        value = value.strip()
        if key == "path" and value.endswith(")") and " (0x" in value:
            value = value[:value.rindex(" (0x")]
        fields[key] = value
    flush()
    return records


def _is_nanogram_app(registration: Registration) -> bool:
    path = str(registration.path)
    if not path.endswith(".app"):
        return False
    if any(part.endswith(".app") for part in registration.path.parts[:-1]):
        return False
    if any(marker in path for marker in LEFT_ALONE_MARKERS):
        return False
    return (registration.path.name == APP_NAME or registration.identifier == IDENTIFIER
            or registration.name == DISPLAY_NAME)


def nanogram_apps(records: list[Registration]) -> list[Path]:
    seen: dict[Path, None] = {}
    for registration in records:
        if _is_nanogram_app(registration):
            seen.setdefault(registration.path, None)
    return list(seen)


def choose_keep(records: list[Registration], installed: Path = INSTALLED,
                exists: Callable[[Path], bool] = os.path.exists,
                mtime: Callable[[Path], float] = os.path.getmtime) -> Path | None:
    if exists(installed):
        return installed
    present = [path for path in nanogram_apps(records) if exists(path)]
    return max(present, key=mtime, default=None)


def strays(records: list[Registration], keep: Path | None) -> list[Path]:
    return [path for path in nanogram_apps(records) if path != keep]


def _run(arguments: list[str]) -> str:
    return subprocess.run(arguments, capture_output=True, text=True, check=False).stdout


def tidy(run: Callable[[list[str]], str] = _run, exists: Callable[[Path], bool] = os.path.exists,
         mtime: Callable[[Path], float] = os.path.getmtime, dry_run: bool = False) -> list[Path]:
    records = parse_dump(run([LSREGISTER, "-dump"]))
    removed = strays(records, choose_keep(records, exists=exists, mtime=mtime))
    if not dry_run:
        for path in removed:
            run([LSREGISTER, "-u", str(path)])
    return removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg apps", description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="list the copies that would be unregistered")
    parser.add_argument("--quiet", action="store_true", help="print nothing when there is nothing to do")
    options = parser.parse_args(argv)
    if not Path(LSREGISTER).exists():
        return 0
    removed = tidy(dry_run=options.dry_run)
    if removed or not options.quiet:
        verb = "would unregister" if options.dry_run else "unregistered"
        print(f"Spotlight: {verb} {len(removed)} extra Nanogram cop{'y' if len(removed) == 1 else 'ies'}")
        if options.dry_run:
            for path in removed:
                print(f"  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
