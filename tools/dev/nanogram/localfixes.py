"""Local working-tree fixes inside submodules we do not fork yet, applied idempotently by tg setup and tg build.

Xcode 27 copies `.copy("*.metal")` package resources as source instead of compiling them, and MetalEngine then
traps at launch (upstream XCODE27.md item 3, applied locally by upstream's scripts/xcode27.sh). Our own copies
of CallVideoLayer and DustLayer carry the fix in git; MetalEngine lives in the telegram-ios submodule, which gets
it here until the nanogram-mac branch of our telegram-ios fork carries it (stage 1 task 12).

widget-sandbox's nested QuickJS: Telegram's Mac 13.2 pins widget-sandbox 015392fd, whose QuickJS (1a402cb) lacks the
memory-safety fixes of TelegramMessenger/quickjs master b526a81 (tg-widget-rce, 2026-11-11). The nested checkout is
moved to b526a81, the commit widget-sandbox's own main pins, until a widget-sandbox commit with the XPC channel API
carries it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import subprocess

from nanogram import config

SHADER_MANIFESTS = (
    "packages/CallVideoLayer/Package.swift",
    "packages/DustLayer/Package.swift",
    "submodules/telegram-ios/submodules/MetalEngine/Package.swift",
)
# Same pattern as upstream's scripts/xcode27.sh SHADER_RESOURCES.
SHADER_RESOURCES = re.compile(r',\s*resources:\s*\[\s*\.copy\("[^"]+\.metal"\)(?:\s*,\s*\.copy\("[^"]+\.metal"\))*\s*\]')


def compile_shaders(manifest: Path) -> bool:
    """Drops copied .metal resources so SwiftPM compiles them into default.metallib; True if it changed the file."""
    text = Path(manifest).read_text()
    fixed = SHADER_RESOURCES.sub("", text)
    if fixed == text:
        return False
    Path(manifest).write_text(fixed)
    return True


WIDGET_QUICKJS_PATH = "third-party/widget-sandbox/packages/ios/Sources/CQuickJS/quickjs"
WIDGET_QUICKJS_COMMIT = "b526a817f188ef861eea7666d68361c7851673a0"


def pin_checkout(checkout: Path, commit: str) -> bool:
    """Checks `checkout` out at `commit` (fetching it if missing); True if it moved. A missing checkout is skipped."""
    checkout = Path(checkout)
    if not (checkout / ".git").exists():
        return False
    def git(*args, check=True):
        return subprocess.run(["git", "-C", str(checkout), *args], capture_output=True, text=True, check=check)
    if git("rev-parse", "HEAD").stdout.strip() == commit:
        return False
    if git("cat-file", "-e", f"{commit}^{{commit}}", check=False).returncode != 0:
        git("fetch", "--quiet", "--no-tags", "origin", commit)
    git("-c", "advice.detachedHead=false", "checkout", "--quiet", commit)
    return True


def main() -> int:
    for relative in SHADER_MANIFESTS:
        manifest = config.ROOT / relative
        if not manifest.is_file():
            print(f"error: {relative} is missing; run tools/dev/tg setup", file=sys.stderr)
            return 1
        if compile_shaders(manifest):
            print(f"localfixes: {relative}: shaders are compiled, not copied (XCODE27.md item 3)")
    if pin_checkout(config.ROOT / WIDGET_QUICKJS_PATH, WIDGET_QUICKJS_COMMIT):
        print(f"localfixes: {WIDGET_QUICKJS_PATH}: QuickJS at {WIDGET_QUICKJS_COMMIT[:10]} (security fixes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
