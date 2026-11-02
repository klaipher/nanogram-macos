"""The two editions: what a built app must look like, and where tg build keeps a copy of each.

mas: sandboxed, no Sparkle (not embedded, not referenced). direct: not sandboxed, hardened runtime, Sparkle.
Both: bundle org.klaipher.Nanogram, the same app group, the same data prefix (Info.plist SOURCE).
"""
from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from nanogram import config
from nanogram.buildcheck import _is_macho, find_app, main_executable

EDITIONS = ("mas", "direct")
BUNDLE_ID = "org.klaipher.Nanogram"
APP_GROUP = "YGTMYL879P.org.klaipher.Nanogram"
SANDBOX = "com.apple.security.app-sandbox"
GROUPS = "com.apple.security.application-groups"
# Entitlements macOS honours only with a provisioning profile: in the distribution set
# (Nanogram-MAS.entitlements, used when exporting with the App Store profile), left out of the
# development set that profile-less local builds sign with.
PROFILE_ONLY_KEYS = ("com.apple.developer.maps",)
SPARKLE_SYMBOL = re.compile(r"_OBJC_CLASS_\$_(SU|SPU)[A-Z]\w*|Sparkle")
APPS_DIR = config.BUILD_OUTPUT / "apps"

__all__ = ["AppFacts", "inspect_app", "check_edition", "stash_app", "stashed_app", "main_executable"]


@dataclass
class AppFacts:
    bundle_id: str
    source: str
    sparkle_embedded: bool
    sparkle_symbols: list[str]
    entitlements: dict
    hardened_runtime: bool
    extension_entitlements: dict = field(default_factory=dict)


def _entitlements(bundle: Path) -> dict:
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)],
                         capture_output=True).stdout
    return plistlib.loads(out) if out.strip() else {}


def _hardened_runtime(bundle: Path) -> bool:
    info = subprocess.run(["codesign", "-dv", str(bundle)], capture_output=True, text=True).stderr
    flags = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", info)
    return bool(flags and "runtime" in flags.group(1).split(","))


def _executables(app: Path) -> list[Path]:
    dirs = [app / "Contents" / "MacOS"] + sorted((app / "Contents" / "PlugIns").glob("*.appex/Contents/MacOS"))
    return [p for d in dirs if d.is_dir() for p in sorted(d.iterdir()) if p.is_file() and _is_macho(p)]


def _sparkle_references(binary: Path) -> list[str]:
    found = []
    undefined = subprocess.run(["nm", "-u", "-j", str(binary)], capture_output=True, text=True).stdout
    found += [s for s in undefined.split() if SPARKLE_SYMBOL.search(s)]
    linked = subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True).stdout
    found += [f"links {line.split()[0]}" for line in linked.splitlines()[1:] if "Sparkle" in line]
    return found


def inspect_app(app: Path) -> AppFacts:
    app = Path(app)
    with (app / "Contents" / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    extensions = sorted((app / "Contents" / "PlugIns").glob("*.appex"))
    symbols = sorted({f"{binary.name}: {s}" for binary in _executables(app) for s in _sparkle_references(binary)})
    return AppFacts(
        bundle_id=info.get("CFBundleIdentifier", ""),
        source=info.get("SOURCE", ""),
        sparkle_embedded=(app / "Contents" / "Frameworks" / "Sparkle.framework").exists(),
        sparkle_symbols=symbols,
        entitlements=_entitlements(app),
        hardened_runtime=_hardened_runtime(app),
        extension_entitlements=_entitlements(extensions[0]) if extensions else {},
    )


def check_edition(facts: AppFacts, edition: str) -> list[str]:
    if edition not in EDITIONS:
        return [f"unknown edition {edition!r}"]
    problems = []
    if facts.bundle_id != BUNDLE_ID:
        problems.append(f"bundle identifier is {facts.bundle_id!r}, expected {BUNDLE_ID}")
    if APP_GROUP not in facts.entitlements.get(GROUPS, []):
        problems.append(f"app is missing the app group {APP_GROUP}")
    if APP_GROUP not in facts.extension_entitlements.get(GROUPS, []):
        problems.append(f"share extension is missing the app group {APP_GROUP}")
    if facts.extension_entitlements.get(SANDBOX) is not True:
        problems.append("share extension is not sandboxed")
    sandboxed = facts.entitlements.get(SANDBOX) is True
    if edition == "mas":
        if not sandboxed:
            problems.append("mas app is not sandboxed")
        if facts.sparkle_embedded:
            problems.append("mas app embeds Contents/Frameworks/Sparkle.framework")
        problems += [f"mas app references Sparkle: {s}" for s in facts.sparkle_symbols]
        if "com.apple.developer.associated-domains" in facts.entitlements:
            problems.append("mas app claims associated domains (Telegram's webcredentials)")
    else:
        if sandboxed:
            problems.append("direct app is sandboxed")
        if not facts.sparkle_embedded:
            problems.append("direct app does not embed Sparkle.framework")
        if not facts.hardened_runtime:
            problems.append("direct app is not signed with the hardened runtime")
    return problems


def _edition_dir(configuration: str, edition: str) -> Path:
    return APPS_DIR / f"{configuration}-{edition}"


def stash_app(products: Path, configuration: str, edition: str) -> Path:
    """Keeps an APFS clone of the built app per edition, so both editions exist side by side."""
    app = find_app(products)
    target_dir = _edition_dir(configuration, edition)
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True)
    target = target_dir / app.name
    subprocess.run(["cp", "-c", "-R", str(app), str(target)], check=True)
    return target


def stashed_app(configuration: str, edition: str) -> Path:
    apps = sorted(_edition_dir(configuration, edition).glob("*.app"))
    if len(apps) != 1:
        raise FileNotFoundError(f"no {configuration} {edition} app in {_edition_dir(configuration, edition)}")
    return apps[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg editions")
    parser.add_argument("--edition", required=True, choices=EDITIONS)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--products", type=Path, help="stash the app from this products dir first")
    args = parser.parse_args(argv)
    app = stash_app(args.products, args.configuration, args.edition) if args.products else \
        stashed_app(args.configuration, args.edition)
    problems = check_edition(inspect_app(app), args.edition)
    for problem in problems:
        print(f"editions: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"editions: {args.edition} ok ({app.relative_to(config.ROOT) if app.is_relative_to(config.ROOT) else app})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
