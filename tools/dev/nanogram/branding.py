"""What a built app must not carry from Telegram (update, crash-report and store endpoints) and what it must
be called. Scans every file in the bundle as bytes, the same as `strings` piped to grep, but in one pass.
"""
from __future__ import annotations

import plistlib
from pathlib import Path

APP_NAME = "Nanogram"
# Telegram's Sparkle feeds, its AppCenter feed, the MTProto updater bot and channels, and its App Store id.
FORBIDDEN = (
    b"mac-updates.telegram.org",
    b"osx.telegram.org/updates",
    b"macos_stable_updater_bot",
    b"api.appcenter.ms",
    b"macos_stable_updates_xml",
    b"macos_beta_updates_xml",
    b"id747648890",
)
OUR_STORE_LINK = b"apps.apple.com/app/id6829268176"
UPSTREAM_COPYRIGHT = "Telegram. All rights reserved"
CHUNK = 8 << 20

__all__ = ["APP_NAME", "FORBIDDEN", "OUR_STORE_LINK", "find_forbidden", "contains", "check_names"]


def _files(app: Path):
    return sorted(p for p in Path(app).rglob("*") if p.is_file() and not p.is_symlink())


def _patterns_in(path: Path, patterns: tuple[bytes, ...]) -> set[bytes]:
    found: set[bytes] = set()
    overlap = max(len(p) for p in patterns) - 1
    tail = b""
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            window = tail + chunk
            found.update(p for p in patterns if p not in found and p in window)
            if len(found) == len(patterns):
                break
            tail = window[-overlap:]
    return found


def find_forbidden(app: Path) -> list[str]:
    """`<path in bundle>: <pattern>` for every forbidden pattern in any file of the bundle."""
    app = Path(app)
    hits = []
    for path in _files(app):
        found = _patterns_in(path, FORBIDDEN)
        hits += [f"{path.relative_to(app)}: {p.decode()}" for p in FORBIDDEN if p in found]
    return hits


def contains(app: Path, pattern: bytes) -> bool:
    return any(_patterns_in(path, (pattern,)) for path in _files(app))


def _plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def check_names(app: Path) -> list[str]:
    app = Path(app)
    info = _plist(app / "Contents" / "Info.plist")
    problems = []
    if app.name != f"{APP_NAME}.app":
        problems.append(f"app bundle is {app.name}, expected {APP_NAME}.app")
    if info.get("CFBundleExecutable") != APP_NAME:
        problems.append(f"CFBundleExecutable is {info.get('CFBundleExecutable')!r}, expected {APP_NAME}")
    if info.get("CFBundleName") != APP_NAME:
        problems.append(f"CFBundleName is {info.get('CFBundleName')!r}, expected {APP_NAME}")
    if UPSTREAM_COPYRIGHT in info.get("NSHumanReadableCopyright", ""):
        problems.append("NSHumanReadableCopyright is Telegram's")
    for extension in sorted((app / "Contents" / "PlugIns").glob("*.appex")):
        name = _plist(extension / "Contents" / "Info.plist").get("CFBundleDisplayName")
        if name != APP_NAME:
            problems.append(f"{extension.name} CFBundleDisplayName is {name!r}, expected {APP_NAME}")
    return problems
