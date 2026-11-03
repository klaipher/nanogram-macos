"""What a built app must not carry from Telegram (update, crash-report and store endpoints) and what it must
be called. Scans every file in the bundle as bytes, the same as `strings` piped to grep, but in one pass.
"""
from __future__ import annotations

import hashlib
import os
import plistlib
import re
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

# Telegram's artwork as upstream ships it (sha256 at the fork's first commit): the app icon, the menu bar glyph,
# the share extension's sign-in logo and icon.
TELEGRAM_ARTWORK = {
    "0dfcb4126d470dc113e679b2d388430f66fceb4dae9822715b8dcdaf57099dcb": "app icon 1024",
    "57900021cc21a842ed8b1af50955f3ab7cf12883a2e6bd1d4ca80d75b5422528": "app icon 512",
    "e8deb6e7ff5803ea4cc294b8b886bcec528813d70ed64fc379ff8d444d10281f": "app icon 256",
    "aade3a3cec3c143649a23b627a07fb8e92a8d7cec78f7bbfce887de8552d765b": "app icon 128",
    "a1f20499e0f5833879091a67690b8641aa6785f23dcb8401e27f9f55f45307b1": "app icon 64",
    "fb96d76e751c04a0fe4e81f0736b91e4014a2bb1ea8e207eb536523c5b5e8e0f": "app icon 32",
    "580785ac0d5599d5e0de9fa3a18da37fa25b0a4faab16c87a49dfbcf27d9f4c1": "app icon 16",
    "8afbbe6a35660fccf9bbe284e07df14ade4817b248e302aba38b589b3c3260ba": "menu bar plane",
    "8f3b98dec795a6a74cd9cdaaf3beb019bd6d2e729ca3cf45c2a3b6dfa1f96a5d": "menu bar plane @2x",
    "5f5c57d00d9b7ca02fcdb1116bbe5b1e28bb8792dbba277eb67aa2589478b61c": "share sign-in logo",
    "a8ad22dae8b1eedf9149aa7023de1663b64bccf48a715063f61fb19a57f87e8d": "share sign-in logo @2x",
    "5e75d06551724df1acf5f5842ec07e8c887939bd8f0d027cd0580d6a5621de78": "share extension icon",
}
ARTWORK_ROOTS = ("Telegram-Mac/Assets.xcassets", "TelegramShare")
# Telegram's plane animation may only stay in the enum that lists bundled animations and in the screens whose
# replacement the owner has not decided yet (the invite link QR code).
PLANE_ANIMATION = re.compile(r"\blogin_airplane\b")
PLANE_ALLOWED = {
    "packages/LocalAnimations/Sources/LocalAnimations/LottieLocalAnimations.swift",
    "packages/InviteLinksUI/Sources/InviteLinksUI/InviteLinkQrController.swift",
}
SOURCE_ROOTS = ("packages", "Telegram-Mac", "TelegramShare")
TELEGRAM_DEFAULT_TITLE = re.compile(r"header\s*:\s*String\??\s*=\s*\"Telegram\"")
IDENTITY_KEYS = Path("packages/NanogramKit/Sources/NanogramKit/BrandingKeys.swift")
ENGLISH_STRINGS = Path("Telegram-Mac/en.lproj/Localizable.strings")
COMET_LOGO = Path("Telegram-Mac/Assets.xcassets/Icon_NanogramComet.imageset/NanogramComet.pdf")

__all__ = ["APP_NAME", "FORBIDDEN", "OUR_STORE_LINK", "TELEGRAM_ARTWORK", "find_forbidden", "contains",
           "check_names", "identity_keys", "english_keys", "check_sources"]


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


def identity_keys(root: Path) -> set[str]:
    return set(re.findall(r'^\s*"([^"]+)",?\s*$', (Path(root) / IDENTITY_KEYS).read_text(), re.M))


def english_keys(root: Path) -> set[str]:
    data = (Path(root) / ENGLISH_STRINGS).read_bytes()
    text = data.decode("utf-16") if data[:2] in (b"\xff\xfe", b"\xfe\xff") else data.decode("utf-8")
    return set(re.findall(r'^"((?:[^"\\]|\\.)+)"\s*=', text, re.M))


def _swift_files(root: Path):
    for top in SOURCE_ROOTS:
        for directory, folders, files in os.walk(root / top):
            folders[:] = sorted(folder for folder in folders if not folder.startswith(".") and folder != "Resources")
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield Path(directory) / name


def check_sources(root: Path) -> list[str]:
    """Where the checkout would show Telegram's name or artwork as this app's: identity string keys that no longer
    exist (renamed upstream), Telegram's icons back in the asset catalogs, the login plane animation, and alerts
    titled "Telegram" by default."""
    root = Path(root)
    problems = []
    english = english_keys(root)
    plural = re.compile(r"_(zero|one|two|few|many|other)$")
    present = english | {plural.sub("", key) for key in english}
    problems += [f"identity key {key} is not in {ENGLISH_STRINGS}" for key in sorted(identity_keys(root) - present)]
    for top in ARTWORK_ROOTS:
        for path in sorted((root / top).rglob("*")):
            if path.is_file() and path.suffix in (".png", ".icns", ".pdf", ".tiff"):
                name = TELEGRAM_ARTWORK.get(hashlib.sha256(path.read_bytes()).hexdigest())
                if name:
                    problems.append(f"{path.relative_to(root)} is Telegram's {name}")
    if not (root / COMET_LOGO).is_file():
        problems.append(f"{COMET_LOGO} is missing")
    for path in _swift_files(root):
        relative = path.relative_to(root).as_posix()
        text = path.read_text(errors="replace")
        if relative not in PLANE_ALLOWED and PLANE_ANIMATION.search(text):
            problems.append(f"{relative} uses Telegram's plane animation (login_airplane)")
        if TELEGRAM_DEFAULT_TITLE.search(text):
            problems.append(f"{relative} titles alerts \"Telegram\" by default")
    return problems
