"""The two editions: what a built app must look like, and where tg build keeps a copy of each.

mas: sandboxed, no Sparkle (not embedded, not referenced). direct: not sandboxed, hardened runtime, Sparkle.
Both: bundle org.klaipher.Nanogram, the same app group, the same data prefix (Info.plist SOURCE).
"""
from __future__ import annotations

import argparse
import hashlib
import base64
import binascii
import plistlib
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from nanogram import branding, config, sparkle
from nanogram.buildcheck import _is_macho, find_app, main_executable

EDITIONS = ("mas", "direct")
BUNDLE_ID = "org.klaipher.Nanogram"
APP_GROUP = "YGTMYL879P.org.klaipher.Nanogram"
SANDBOX = "com.apple.security.app-sandbox"
GROUPS = "com.apple.security.application-groups"
# Entitlements macOS honours only with a provisioning profile: in the distribution set
# (Nanogram-MAS.entitlements, used when exporting with the App Store profile), left out of the
# development set that profile-less local builds sign with.
PROFILE_ONLY_KEYS = ("com.apple.developer.maps", "com.apple.developer.usernotifications.communication")
SPARKLE_FEED_URL = sparkle.FEED_URL
SPARKLE_SYMBOL = re.compile(r"_OBJC_CLASS_\$_(SU|SPU)[A-Z]\w*|Sparkle")
APPS_DIR = config.BUILD_OUTPUT / "apps"

__all__ = ["AppFacts", "inspect_app", "check_edition", "stash_app", "stashed_app", "main_executable",
           "refresh_build_descriptions", "product_fingerprint", "fingerprint_file"]


@dataclass
class AppFacts:
    bundle_id: str
    source: str
    sparkle_embedded: bool
    sparkle_symbols: list[str]
    entitlements: dict
    hardened_runtime: bool
    extension_entitlements: dict = field(default_factory=dict)
    sparkle_feed: str = ""
    sparkle_public_key: str = ""
    decoder_present: bool = False
    decoder_entitlements: dict = field(default_factory=dict)
    decoder_hardened_runtime: bool = True


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
    decoders = sorted((app / "Contents" / "XPCServices").glob("NanogramDecoder.xpc"))
    symbols = sorted({f"{binary.name}: {s}" for binary in _executables(app) for s in _sparkle_references(binary)})
    return AppFacts(
        bundle_id=info.get("CFBundleIdentifier", ""),
        source=info.get("SOURCE", ""),
        sparkle_embedded=(app / "Contents" / "Frameworks" / "Sparkle.framework").exists(),
        sparkle_symbols=symbols,
        entitlements=_entitlements(app),
        hardened_runtime=_hardened_runtime(app),
        extension_entitlements=_entitlements(extensions[0]) if extensions else {},
        sparkle_feed=info.get("SUFeedURL", ""),
        sparkle_public_key=info.get("SUPublicEDKey", ""),
        decoder_present=bool(decoders),
        decoder_entitlements=_entitlements(decoders[0]) if decoders else {},
        decoder_hardened_runtime=_hardened_runtime(decoders[0]) if decoders else True,
    )


def _is_ed25519_public_key(value: str) -> bool:
    try:
        return len(base64.b64decode(value, validate=True)) == 32
    except (binascii.Error, ValueError):
        return False


DECODER_FORBIDDEN_PREFIXES = ("com.apple.security.network.", "com.apple.security.files.", "com.apple.security.temporary-exception",
                              "com.apple.security.device.", "com.apple.security.personal-information.")


def _check_decoder_service(facts: AppFacts) -> list[str]:
    problems = []
    if facts.decoder_entitlements.get(SANDBOX) is not True:
        problems.append("decoder service is not sandboxed")
    problems += [f"decoder service has the entitlement {key}" for key in sorted(facts.decoder_entitlements)
                 if key.startswith(DECODER_FORBIDDEN_PREFIXES)]
    if not facts.decoder_hardened_runtime:
        problems.append("decoder service is not signed with the hardened runtime")
    return problems


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
    if facts.decoder_present:
        problems += _check_decoder_service(facts)
    sandboxed = facts.entitlements.get(SANDBOX) is True
    if edition == "mas":
        if not sandboxed:
            problems.append("mas app is not sandboxed")
        if facts.sparkle_embedded:
            problems.append("mas app embeds Contents/Frameworks/Sparkle.framework")
        problems += [f"mas app references Sparkle: {s}" for s in facts.sparkle_symbols]
        if facts.sparkle_feed:
            problems.append(f"mas app has a SUFeedURL ({facts.sparkle_feed})")
        if "com.apple.developer.associated-domains" in facts.entitlements:
            problems.append("mas app claims associated domains (Telegram's webcredentials)")
    else:
        if sandboxed:
            problems.append("direct app is sandboxed")
        if not facts.sparkle_embedded:
            problems.append("direct app does not embed Sparkle.framework")
        if not facts.hardened_runtime:
            problems.append("direct app is not signed with the hardened runtime")
        if facts.sparkle_feed != SPARKLE_FEED_URL:
            problems.append(f"direct app SUFeedURL is {facts.sparkle_feed!r}, expected {SPARKLE_FEED_URL}")
        if not _is_ed25519_public_key(facts.sparkle_public_key):
            problems.append("direct app has no valid SUPublicEDKey (base64 32-byte ed25519 key): see tg sparkle-key")
    return problems


INCLUDE_RE = re.compile(r'^\s*#include\??\s+"([^"]+)"', re.M)


def _xcconfig_files(xcconfig: Path) -> list[Path]:
    files, pending = [], [Path(xcconfig)]
    while pending:
        path = pending.pop(0).resolve()
        if path in files or not path.is_file():
            continue
        files.append(path)
        pending += [path.parent / name for name in INCLUDE_RE.findall(path.read_text())]
    return files


def refresh_build_descriptions(xcconfig: Path, edition: str, derived: Path) -> bool:
    """Drops Xcode's cached build descriptions when this edition's xcconfig (or one it includes) changed since
    the edition was last built. Xcode can reuse a cached description without re-reading the -xcconfig file
    (mas build, edit direct.xcconfig, direct build: the new setting never reached Info.plist). Only the
    *.xcbuilddata descriptions go; build.db and compiled objects stay, so the build stays incremental."""
    digest = hashlib.sha256()
    for path in _xcconfig_files(xcconfig):
        digest.update(str(path).encode() + b"\0" + path.read_bytes() + b"\0")
    stamp = Path(derived) / f"nanogram-xcconfig-{edition}.sha256"
    unchanged = stamp.is_file() and stamp.read_text().strip() == digest.hexdigest()
    if not unchanged:
        for description in (Path(derived) / "Build" / "Intermediates.noindex" / "XCBuildData").glob("*.xcbuilddata"):
            shutil.rmtree(description)
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(digest.hexdigest() + "\n")
    return not unchanged


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


CDHASH_RE = re.compile(r"^(?:CandidateCDHashFull sha256|CDHash)=([0-9a-f]+)$", re.M)


def product_fingerprint(app: Path) -> str:
    """The hash of the app's CodeDirectory, or "" for an unsigned app. It covers the main executable, Info.plist,
    entitlements, runtime flags and, through CodeResources, every resource and nested code's own hash (debug dylib,
    extension, Sparkle). Re-signing identical contents keeps it; the signing time and file times do not count."""
    info = subprocess.run(["codesign", "-dvvv", str(app)], capture_output=True, text=True).stderr
    hashes = CDHASH_RE.findall(info)
    if not hashes:
        return ""
    return hashlib.sha256(f"nanogram-editions=1\n{hashes[0]}\n".encode()).hexdigest()


def fingerprint_file(configuration: str, edition: str) -> Path:
    return APPS_DIR / f"{configuration}-{edition}.fingerprint"


def _unchanged_since_last_check(fingerprint: str, configuration: str, edition: str) -> bool:
    stored = fingerprint_file(configuration, edition)
    if not fingerprint or not stored.is_file() or stored.read_text().strip() != fingerprint:
        return False
    try:
        stashed_app(configuration, edition)
    except FileNotFoundError:
        return False
    return True


def stashed_app(configuration: str, edition: str) -> Path:
    apps = sorted(_edition_dir(configuration, edition).glob("*.app"))
    if len(apps) != 1:
        raise FileNotFoundError(f"no {configuration} {edition} app in {_edition_dir(configuration, edition)}")
    return apps[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg editions")
    parser.add_argument("--edition", required=True, choices=EDITIONS)
    parser.add_argument("--configuration")
    parser.add_argument("--products", type=Path, help="stash the app from this products dir first")
    parser.add_argument("--before-build", type=Path, metavar="DERIVED_DATA",
                        help="only drop stale build descriptions for this edition, then exit")
    args = parser.parse_args(argv)
    if args.before_build:
        xcconfig = config.ROOT / "nanogram" / "editions" / f"{args.edition}.xcconfig"
        if refresh_build_descriptions(xcconfig, args.edition, args.before_build):
            print(f"editions: {args.edition} settings changed since its last build; Xcode recomputes its build description")
        return 0
    if not args.configuration:
        parser.error("--configuration is required")
    fingerprint = None
    if args.products:
        built = find_app(args.products)
        fingerprint = product_fingerprint(built)
        if _unchanged_since_last_check(fingerprint, args.configuration, args.edition):
            print(f"editions: {args.edition} ok (unchanged since the last check)")
            return 0
        fingerprint_file(args.configuration, args.edition).unlink(missing_ok=True)
        app = stash_app(args.products, args.configuration, args.edition)
    else:
        app = stashed_app(args.configuration, args.edition)
    problems = check_edition(inspect_app(app), args.edition)
    problems += branding.check_names(app)
    problems += [f"Telegram endpoint in the bundle: {hit}" for hit in branding.find_forbidden(app)]
    for problem in problems:
        print(f"editions: {problem}", file=sys.stderr)
    if problems:
        return 1
    if fingerprint:
        fingerprint_file(args.configuration, args.edition).write_text(fingerprint + "\n")
    print(f"editions: {args.edition} ok ({app.relative_to(config.ROOT) if app.is_relative_to(config.ROOT) else app})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
