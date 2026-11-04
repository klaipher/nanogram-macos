"""Apple Enhanced Security entitlements for the Mac app, in soft mode.

The app's entitlement files stay the source of truth. The hardened variants (`<name>-EnhancedSecurity.entitlements`)
are generated from them by `python3 -m nanogram.enhanced_security` and checked by tests; the editions pick the
variant only when NANOGRAM_ENHANCED_SECURITY_REQUEST=YES is passed to the build (tg adds it to release builds when
NANOGRAM_ENHANCED_SECURITY=1 is set), because the App ID needs the Enhanced Security capability and a regenerated
profile first. Soft mode makes hardware memory tagging log a simulated crash instead of ending the process; dyld-ro
and platform restrictions have no soft mode and are not part of it.
"""
from __future__ import annotations

import plistlib
from pathlib import Path

from nanogram import config

PREFIX = "com.apple.security.hardened-process"
SOFT_MODE_KEYS = {
    PREFIX: True,
    f"{PREFIX}.enhanced-security-version-string": "1",
    f"{PREFIX}.checked-allocations": True,
    f"{PREFIX}.checked-allocations.soft-mode": True,
}
BASES = ("Nanogram-Direct", "Nanogram-MAS", "Nanogram-MAS-Development")
SUFFIX = "-EnhancedSecurity"
DIRECTORY = config.ROOT / "nanogram" / "entitlements"


def hardened_entitlements(base: Path) -> bytes:
    entitlements = plistlib.loads(Path(base).read_bytes())
    entitlements.update(SOFT_MODE_KEYS)
    return plistlib.dumps(dict(sorted(entitlements.items())))


def variant_path(base: Path) -> Path:
    base = Path(base)
    return base.with_name(f"{base.stem}{SUFFIX}{base.suffix}")


def write_variants(directory: Path = DIRECTORY) -> list[Path]:
    written = []
    for name in BASES:
        base = Path(directory) / f"{name}.entitlements"
        target = variant_path(base)
        target.write_bytes(hardened_entitlements(base))
        written.append(target)
    return written


def main() -> int:
    for path in write_variants():
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
