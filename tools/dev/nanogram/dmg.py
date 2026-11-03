"""The installer disk image window: a fixed 640x400 icon view with the app on the left, an Applications link on the
right, the background from tools/dev/dmg (render-background.swift) and the app icon as the volume icon. The layout is
written as a .DS_Store on a mounted read-write image, without Finder or AppleScript, then the image is compressed."""
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from nanogram import config, dsstore

__all__ = ["VOLUME_NAME", "WINDOW_SIZE", "BACKGROUND_SIZE", "ICON_SIZE", "APP_POSITION", "APPLICATIONS_POSITION", "BACKGROUND",
           "app_icon", "layout_records", "build"]

VOLUME_NAME = "Nanogram"
WINDOW_ORIGIN = (200, 260)
WINDOW_SIZE = (640, 400)
BACKGROUND_SIZE = (2560, 1600)
TITLE_BAR_HEIGHT = 28
ICON_SIZE = 128
APP_POSITION = (160, 190)
APPLICATIONS_POSITION = (480, 190)
BACKGROUND = config.ROOT / "tools" / "dev" / "dmg" / "background.tiff"
BACKGROUND_PATH = Path(".background") / "background.tiff"
VOLUME_ICON = ".VolumeIcon.icns"
FALLBACK_ICON = config.ROOT / "TelegramShare" / "icon.icns"
CUSTOM_ICON_FINDER_INFO = "00" * 8 + "0400" + "00" * 22
SIZE_MARGIN = 32 * 1024 * 1024


def app_icon(app: Path) -> Path:
    try:
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException):
        info = {}
    name = info.get("CFBundleIconFile")
    if name:
        icon = app / "Contents" / "Resources" / (name if name.endswith(".icns") else f"{name}.icns")
        if icon.is_file():
            return icon
    return FALLBACK_ICON


def layout_records(app_name: str, background_alias: bytes) -> list[dsstore.Record]:
    (x, y), (width, height) = WINDOW_ORIGIN, WINDOW_SIZE
    window = {
        "WindowBounds": f"{{{{{x}, {y}}}, {{{width}, {height + TITLE_BAR_HEIGHT}}}}}",
        "ShowToolbar": False, "ShowSidebar": False, "ContainerShowSidebar": False, "ShowStatusBar": False,
        "ShowTabView": False, "ShowPathbar": False, "PreviewPaneVisibility": False, "SidebarWidth": 0,
    }
    icon_view = {
        "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": background_alias,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "arrangeBy": "none",
        "showIconPreview": False, "showItemInfo": False, "labelOnBottom": True, "textSize": 12.0,
        "iconSize": float(ICON_SIZE), "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    records = [
        dsstore.Record(".", "bwsp", "blob", plistlib.dumps(window, fmt=plistlib.FMT_BINARY)),
        dsstore.Record(".", "icvp", "blob", plistlib.dumps(icon_view, fmt=plistlib.FMT_BINARY)),
        dsstore.Record(".", "icvl", "type", "icnv"),
        dsstore.Record(".", "vstl", "type", "icnv"),
        dsstore.Record(".", "vSrn", "long", 1),
        dsstore.Record(app_name, "Iloc", "blob", dsstore.iloc(*APP_POSITION)),
        dsstore.Record("Applications", "Iloc", "blob", dsstore.iloc(*APPLICATIONS_POSITION)),
    ]
    return records


def _tree_size(path: Path) -> int:
    total = 0
    for directory, _, files in os.walk(path):
        for name in files:
            total += os.lstat(os.path.join(directory, name)).st_size
    return total


def _attach(image: Path, parent: Path) -> Path:
    listing = subprocess.run(["hdiutil", "attach", "-plist", "-readwrite", "-nobrowse", "-noverify", "-noautoopen",
                              "-mountrandom", str(parent), str(image)],
                             capture_output=True, check=True).stdout
    mounts = [entity["mount-point"] for entity in plistlib.loads(listing)["system-entities"]
              if entity.get("mount-point")]
    if not mounts:
        raise RuntimeError(f"hdiutil attach mounted no volume from {image}")
    return Path(mounts[0])


def _stage(app: Path, staging: Path) -> None:
    subprocess.run(["ditto", str(app), str(staging / app.name)], check=True)
    (staging / "Applications").symlink_to("/Applications")
    (staging / BACKGROUND_PATH).parent.mkdir()
    shutil.copyfile(BACKGROUND, staging / BACKGROUND_PATH)
    shutil.copyfile(app_icon(app), staging / VOLUME_ICON)


def _lay_out(mount: Path, app_name: str) -> None:
    background = mount / BACKGROUND_PATH
    background_alias = dsstore.alias(background, mount, VOLUME_NAME)
    dsstore.write(mount / ".DS_Store", layout_records(app_name, background_alias))
    subprocess.run(["xattr", "-wx", "com.apple.FinderInfo", CUSTOM_ICON_FINDER_INFO, str(mount)], check=True)
    subprocess.run(["chflags", "hidden", str(mount / BACKGROUND_PATH.parent), str(mount / VOLUME_ICON)],
                   check=True)
    for scratch in (".fseventsd", ".Trashes"):
        shutil.rmtree(mount / scratch, ignore_errors=True)


def build(app: Path, out: Path) -> Path:
    """A compressed APFS image (ULFO) named VOLUME_NAME holding the app, an Applications link, the background and
    volume icon, and the window layout."""
    app, out = Path(app), Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{out.stem}.", dir=out.parent) as work:
        work = Path(work)
        staging, mounts, writable = work / "staging", work / "mounts", work / "writable.dmg"
        staging.mkdir()
        mounts.mkdir()
        _stage(app, staging)
        size_mb = (_tree_size(staging) + SIZE_MARGIN) // (1024 * 1024) + 1
        subprocess.run(["hdiutil", "create", "-quiet", "-volname", VOLUME_NAME, "-srcfolder", str(staging),
                        "-fs", "APFS", "-format", "UDRW", "-size", f"{size_mb}m", str(writable)], check=True)
        mount = _attach(writable, mounts)
        try:
            _lay_out(mount, app.name)
        finally:
            subprocess.run(["hdiutil", "detach", str(mount), "-quiet"], check=False)
            if mount.exists() and os.path.ismount(mount):
                subprocess.run(["hdiutil", "detach", str(mount), "-force", "-quiet"], check=True)
        if out.exists():
            out.unlink()
        subprocess.run(["hdiutil", "convert", "-quiet", str(writable), "-format", "ULFO", "-o", str(out)],
                       check=True)
    return out
