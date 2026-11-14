"""Local working-tree fixes inside submodules we do not fork yet, applied idempotently by tg setup and tg build.

Xcode 27 copies `.copy("*.metal")` package resources as source instead of compiling them, and MetalEngine then
traps at launch (upstream XCODE27.md item 3, applied locally by upstream's scripts/xcode27.sh). Our own copies
of CallVideoLayer and DustLayer carry the fix in git; MetalEngine lives in the telegram-ios submodule, which gets
it here until the nanogram-mac branch of our telegram-ios fork carries it (stage 1 task 12).

The widget stack (twidget, widget-sandbox and its QuickJS) is no longer fixed here: the Mac pins the klaipher forks
(branch nanogram) at the same commits as iOS and Android, and the QuickJS security fixes are in klaipher/quickjs.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

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


def main() -> int:
    for relative in SHADER_MANIFESTS:
        manifest = config.ROOT / relative
        if not manifest.is_file():
            print(f"error: {relative} is missing; run tools/dev/tg setup", file=sys.stderr)
            return 1
        if compile_shaders(manifest):
            print(f"localfixes: {relative}: shaders are compiled, not copied (XCODE27.md item 3)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
