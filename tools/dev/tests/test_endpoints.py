"""Telegram-owned update, crash-report and store endpoints never ship, and the app is called Nanogram."""
import os
import plistlib
import sys
import json
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import branding, editions  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
CONFIGURATION = os.environ.get("NANOGRAM_EDITIONS_CONFIGURATION", "Debug")


def built(edition):
    try:
        return editions.stashed_app(CONFIGURATION, edition)
    except FileNotFoundError:
        return None


APPS = {edition: built(edition) for edition in editions.EDITIONS}
BOTH_BUILT = all(APPS.values())
NOT_BUILT = f"build both editions first: tg build --edition mas && tg build --edition direct ({CONFIGURATION})"


def fake_app(root: Path, name="Nanogram", executable="Nanogram", payload=b"", share_name="Nanogram",
             copyright="Copyright © 2026 klaipher. Based on Telegram for macOS (GPL-2.0).") -> Path:
    app = root / f"{name}.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "MacOS" / executable).write_bytes(b"\xcf\xfa\xed\xfe" + payload)
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(
        {"CFBundleExecutable": executable, "CFBundleName": name, "NSHumanReadableCopyright": copyright}))
    extension = app / "Contents" / "PlugIns" / "TelegramShare.appex" / "Contents"
    extension.mkdir(parents=True)
    (extension / "Info.plist").write_bytes(plistlib.dumps({"CFBundleDisplayName": share_name}))
    return app


class BrandingRulesTests(unittest.TestCase):
    def test_forbidden_endpoint_found_in_any_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp), payload=b"\x00https://mac-updates.telegram.org/updates/versions.xml\x00")
            found = branding.find_forbidden(app)
        self.assertEqual(found, ["Contents/MacOS/Nanogram: mac-updates.telegram.org"])

    def test_clean_app_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp), payload=b"https://apps.apple.com/app/id6829268176")
            self.assertEqual(branding.find_forbidden(app), [])
            self.assertEqual(branding.check_names(app), [])

    def test_telegram_names_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp), name="Telegram", executable="Telegram", share_name="Telegram",
                           copyright="Copyright © 2024 Telegram. All rights reserved.")
            problems = branding.check_names(app)
        self.assertEqual(len(problems), 5, problems)

    def test_pattern_split_across_read_chunks_is_found(self):
        pattern = b"macos_stable_updater_bot"
        payload = b"x" * (branding.CHUNK - 10) + pattern
        with tempfile.TemporaryDirectory() as tmp:
            app = fake_app(Path(tmp), payload=payload)
            self.assertEqual(branding.find_forbidden(app), ["Contents/MacOS/Nanogram: macos_stable_updater_bot"])


def png_pixels(path: Path):
    """(width, rows of RGBA tuples) for an 8-bit RGBA or RGB, non-interlaced PNG."""
    data = path.read_bytes()
    pos, chunks = 8, {}
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunks.setdefault(kind, []).append(data[pos + 8:pos + 8 + length])
        pos += 12 + length
    width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunks[b"IHDR"][0])
    assert depth == 8 and color in (2, 6) and interlace == 0, (depth, color, interlace)
    channels = 4 if color == 6 else 3
    raw = zlib.decompress(b"".join(chunks[b"IDAT"]))
    stride, rows, previous = width * channels, [], bytearray(width * channels)
    for y in range(height):
        kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up, corner = previous[i], previous[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        rows.append([tuple(line[x * channels:(x + 1) * channels]) + ((255,) if channels == 3 else ())
                     for x in range(width)])
        previous = line
    return width, rows


def close(rgba, hex_rgb, tolerance=6):
    target = bytes.fromhex(hex_rgb)
    return rgba[3] == 255 and all(abs(a - b) <= tolerance for a, b in zip(rgba, target))


class IconTests(unittest.TestCase):
    """The rendered macOS icon is the dark Comet in Apple's icon grid (rounded square, transparent margin)."""

    def test_app_icon_is_the_comet(self):
        width, rows = png_pixels(ROOT / "Telegram-Mac/Assets.xcassets/AppIcon.appiconset/Logo_1024.png")
        self.assertEqual(width, 1024)
        self.assertEqual(rows[4][4][3], 0, "the corner outside the rounded square must be transparent")
        self.assertTrue(close(rows[431][593], "508FFF"), rows[431][593])
        self.assertTrue(close(rows[784][784], "111722"), rows[784][784])

    def test_every_size_rendered(self):
        icons = json.loads((ROOT / "Telegram-Mac/Assets.xcassets/AppIcon.appiconset/Contents.json").read_text())
        for image in icons["images"]:
            points, scale = int(image["size"].split("x")[0]), int(image["scale"][0])
            width, _ = png_pixels(ROOT / "Telegram-Mac/Assets.xcassets/AppIcon.appiconset" / image["filename"])
            self.assertEqual(width, points * scale, image["filename"])

    def test_liquid_glass_icon_is_nanogram(self):
        icon = json.loads((ROOT / "Telegram-Mac/AppIcon.icon/icon.json").read_text())
        self.assertEqual(icon["fill"], {"solid": "srgb:0.06667,0.09020,0.13333,1.00000"})
        images = sorted(layer["image-name"] for group in icon["groups"] for layer in group["layers"])
        self.assertEqual(images, ["Head.svg", "Tail.svg"])
        self.assertIn('fill="#508FFF"', (ROOT / "Telegram-Mac/AppIcon.icon/Assets/Head.svg").read_text())


@unittest.skipUnless(BOTH_BUILT, NOT_BUILT)
class BuiltAppsTests(unittest.TestCase):
    def test_no_telegram_update_endpoints_in_binary(self):
        for edition, app in APPS.items():
            with self.subTest(edition=edition):
                self.assertEqual(branding.find_forbidden(app), [])

    def test_our_store_link_in_binary(self):
        for edition, app in APPS.items():
            with self.subTest(edition=edition):
                self.assertTrue(branding.contains(app, branding.OUR_STORE_LINK), f"{edition}: no {branding.OUR_STORE_LINK}")

    def test_app_is_called_nanogram(self):
        for edition, app in APPS.items():
            with self.subTest(edition=edition):
                self.assertEqual(app.name, "Nanogram.app")
                self.assertTrue((app / "Contents" / "MacOS" / "Nanogram").is_file())
                self.assertEqual(branding.check_names(app), [])


if __name__ == "__main__":
    unittest.main()
