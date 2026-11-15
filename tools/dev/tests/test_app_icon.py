"""Nanogram's app icon in the checkout: the Icon Composer document (macOS 26+), the pre-26 asset catalog, the picker."""
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
ICON = ROOT / "Telegram-Mac" / "AppIcon.icon"
APPICONSET = ROOT / "Telegram-Mac" / "Assets.xcassets" / "AppIcon.appiconset"
PICKER = ROOT / "packages" / "NanogramAppIcons" / "Sources" / "NanogramAppIcons"
PRIMARY = "NanogramSphere"
GRAY_ALPHA, RGB, RGBA = 4, 2, 6


def png_header(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()[:33]
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    width, height, _depth, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type


def layer_image_names(layer: dict) -> set[str]:
    names = {layer["image-name"]} if "image-name" in layer else set()
    names.update(spec["value"] for spec in layer.get("image-name-specializations", []))
    return names


class IconComposerDocumentTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads((ICON / "icon.json").read_text())
        self.layers = [layer for group in self.document["groups"] for layer in group["layers"]]

    def test_the_document_is_layered_and_every_image_exists(self):
        self.assertTrue(1 < len(self.document["groups"]) <= 4, "Icon Composer allows at most four groups")
        for layer in self.layers:
            for name in layer_image_names(layer):
                self.assertTrue((ICON / "Assets" / name).is_file(), name)
        self.assertEqual(self.document["supported-platforms"]["squares"], "shared")

    def test_the_background_is_the_bottom_group_and_full_bleed(self):
        background = self.document["groups"][-1]["layers"]
        self.assertEqual([layer["name"] for layer in background], ["Background"])
        for name in layer_image_names(background[0]):
            svg = (ICON / "Assets" / name).read_text()
            self.assertNotIn("rx=", svg, f"{name} is pre-rounded")
            self.assertNotIn("clip-path", svg, f"{name} is pre-masked")
            self.assertIn('<rect width="100" height="100"', svg)

    def test_dark_and_tinted_variants_exist(self):
        appearances = {spec.get("appearance") for layer in self.layers for spec in layer.get("image-name-specializations", [])}
        self.assertTrue({"dark", "tinted"} <= appearances, appearances)

    def test_layers_use_no_filters_and_raster_layers_match_the_canvas(self):
        for path in (ICON / "Assets").iterdir():
            if path.suffix == ".svg":
                self.assertNotIn("<filter", path.read_text(), path.name)
            else:
                width, height, color_type = png_header(path)
                self.assertEqual((width, height), (1024, 1024), path.name)
                self.assertIn(color_type, (GRAY_ALPHA, RGBA), path.name)

    @unittest.skipUnless(shutil.which("xcrun") and Path("/Applications/Xcode.app").is_dir(), "needs Xcode")
    def test_actool_compiles_the_document_for_macos(self):
        with tempfile.TemporaryDirectory() as out:
            result = subprocess.run(
                ["xcrun", "actool", "--compile", out, "--platform", "macosx", "--minimum-deployment-target", "15.0",
                 "--app-icon", "AppIcon", "--output-partial-info-plist", f"{out}/partial.plist", str(ICON)],
                capture_output=True, text=True)
            text = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, text)
            self.assertNotIn("error", text.lower())
            self.assertTrue((Path(out) / "Assets.car").is_file())
            self.assertTrue((Path(out) / "AppIcon.icns").is_file(), "macOS 15 needs the generated .icns fallback")


class PreMacOS26IconTests(unittest.TestCase):
    def test_the_asset_catalog_has_every_macos_size_with_a_transparent_margin(self):
        contents = json.loads((APPICONSET / "Contents.json").read_text())
        sizes = {(image["size"], image["scale"]) for image in contents["images"]}
        expected = {(f"{point}x{point}", f"{scale}x") for point in (16, 32, 128, 256, 512) for scale in (1, 2)}
        self.assertEqual(sizes, expected)
        for image in contents["images"]:
            point, scale = int(image["size"].split("x")[0]), int(image["scale"][0])
            width, height, color_type = png_header(APPICONSET / image["filename"])
            self.assertEqual((width, height), (point * scale, point * scale), image["filename"])
            self.assertEqual(color_type, RGBA, f"{image['filename']} is the macOS template and keeps its alpha")

    def test_both_editions_compile_the_same_primary_icon(self):
        project = (ROOT / "Telegram.xcodeproj" / "project.pbxproj").read_text()
        self.assertGreaterEqual(project.count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"), 2)
        self.assertRegex(project, r"AppIcon\.icon in Resources")
        for edition in ("direct", "mas"):
            xcconfig = (ROOT / "nanogram" / "editions" / f"{edition}.xcconfig").read_text()
            shared = (ROOT / "nanogram" / "Nanogram.xcconfig").read_text()
            self.assertNotIn("APPICON", xcconfig, f"{edition} must not pick another primary icon")
            self.assertNotIn("APPICON", shared)

    def test_the_share_extension_and_installer_use_the_same_artwork(self):
        self.assertTrue((ROOT / "TelegramShare" / "icon.icns").is_file())
        source_file = ROOT / "submodules" / "telegram-ios" / "Telegram" / "Telegram-iOS" / "AlternateIconSources" / f"{PRIMARY}.svg"
        if source_file.is_file():  # the SVGs come from the core (one source for iOS and Mac)
            self.assertNotIn("clip-path", source_file.read_text())
        self.assertIn(f'defaultIconName = "{PRIMARY}"', (ROOT / "tools" / "dev" / "nanogram" / "render-mac-icon.swift").read_text())


class PickerTests(unittest.TestCase):
    def test_the_picker_lists_the_new_icon_first_and_keeps_the_old_ones(self):
        source = (PICKER / "NanogramAppIcon.swift").read_text()
        names = re.findall(r'NanogramAppIcon\(name: "(\w+)"', source)
        self.assertEqual(names[0], PRIMARY)
        self.assertIn("NanogramComet", names)
        self.assertIn("return all[0]", source)
        for name in names:
            self.assertTrue((PICKER / "Icons" / f"{name}.icns").is_file(), name)


if __name__ == "__main__":
    unittest.main()
