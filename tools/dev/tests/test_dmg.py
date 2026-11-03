"""The installer disk image: .DS_Store format, alias record, background artwork and the built image's layout."""
import os
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import dmg, dsstore, release  # noqa: E402


def fake_app(directory: Path, icon: bool = False) -> Path:
    app = directory / "Nanogram.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "MacOS" / "Nanogram").write_text("#!/bin/sh\n")
    if icon:
        (app / "Contents" / "Resources").mkdir()
        (app / "Contents" / "Resources" / "AppIcon.icns").write_bytes(b"icns")
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIconFile": "AppIcon"}))
    return app


def attach_read_only(image: Path, parent: Path) -> Path:
    listing = subprocess.run(["hdiutil", "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-mountrandom",
                              str(parent), str(image)], capture_output=True, check=True).stdout
    return Path(next(entity["mount-point"] for entity in plistlib.loads(listing)["system-entities"]
                     if entity.get("mount-point")))


def relative_luminance(rgb: tuple[int, int, int]) -> float:
    def linear(channel: int) -> float:
        value = channel / 255
        return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
    red, green, blue = map(linear, rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


class DSStoreTests(unittest.TestCase):
    def test_round_trip_keeps_every_record_sorted_by_name_then_code(self):
        records = [
            dsstore.Record("b", "Iloc", "blob", dsstore.iloc(1, 2)),
            dsstore.Record(".", "vSrn", "long", 1),
            dsstore.Record("A", "Iloc", "blob", dsstore.iloc(3, 4)),
            dsstore.Record(".", "icvl", "type", "icnv"),
            dsstore.Record(".", "bwsp", "blob", b"plist"),
            dsstore.Record("Ünïcode", "cmmt", "ustr", "note"),
            dsstore.Record(".", "ph1S", "comp", 1 << 40),
            dsstore.Record(".", "dscl", "bool", True),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".DS_Store"
            dsstore.write(path, records)
            data = path.read_bytes()
            self.assertEqual(data[:8], b"\0\0\0\1Bud1")
            self.assertEqual(dsstore.read(path), sorted(records, key=dsstore.Record.sort_key))

    def test_records_that_do_not_fit_one_node_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(dsstore.NodeOverflow):
                dsstore.write(Path(tmp) / ".DS_Store", [dsstore.Record(".", "pBBk", "blob", b"x" * 5000)])

    def test_iloc_is_the_finder_icon_location_layout(self):
        self.assertEqual(dsstore.iloc(160, 190), struct.pack(">IIII", 160, 190, 0xFFFFFFFF, 0xFFFF0000))

    def test_alias_is_a_version_2_record_of_the_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            volume = Path(tmp).resolve()
            (volume / ".background").mkdir()
            target = volume / ".background" / "background.tiff"
            target.write_bytes(b"tiff")
            record = dsstore.alias(target, volume, "Nanogram")
            size, version, kind = struct.unpack_from(">Hhh", record, 4)
            self.assertEqual((size, version, kind), (len(record), 2, 0))
            self.assertEqual(record[10:10 + 1 + len("Nanogram")], b"\x08Nanogram")
            parent_cnid, = struct.unpack_from(">I", record, 46)
            self.assertEqual(parent_cnid, os.stat(target.parent).st_ino)
            self.assertEqual(record[50:50 + 1 + len("background.tiff")], b"\x0fbackground.tiff")
            target_cnid, = struct.unpack_from(">I", record, 114)
            self.assertEqual(target_cnid, os.stat(target).st_ino)
            self.assertIn(b"/.background/background.tiff", record)
            self.assertIn(b"/Volumes/Nanogram", record)
            self.assertEqual(record[-4:], struct.pack(">hH", -1, 0))


class BackgroundTests(unittest.TestCase):
    def test_background_holds_1x_and_2x_representations(self):
        info = subprocess.run(["tiffutil", "-info", str(dmg.BACKGROUND)], capture_output=True, text=True,
                              check=True).stdout
        width, height = dmg.BACKGROUND_SIZE
        self.assertIn(f"Image Width: {width} Image Length: {height}", info)
        self.assertIn(f"Image Width: {2 * width} Image Length: {2 * height}", info)

    def background_pixels(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bitmap = Path(tmp.name) / "background.bmp"
        subprocess.run(["sips", "-s", "format", "bmp", str(dmg.BACKGROUND), "--out", str(bitmap)],
                       capture_output=True, check=True)
        data = bitmap.read_bytes()
        offset, = struct.unpack_from("<I", data, 10)
        width, height, _, bits = struct.unpack_from("<iiHH", data, 18)
        self.assertEqual((width, abs(height)), dmg.BACKGROUND_SIZE)
        stride = (width * bits // 8 + 3) // 4 * 4

        def pixel(x: int, y: int) -> tuple[int, int, int]:
            row = abs(height) - 1 - y if height > 0 else y
            at = offset + row * stride + x * (bits // 8)
            return data[at + 2], data[at + 1], data[at]
        return pixel

    def test_a_window_larger_than_the_layout_shows_the_backdrop_not_white(self):
        pixel = self.background_pixels()
        window_width, window_height = dmg.WINDOW_SIZE
        width, height = dmg.BACKGROUND_SIZE
        corner = pixel(window_width - 1, window_height - 1)
        for x, y in ((window_width + 8, window_height // 2), (width - 1, 0), (width // 2, window_height),
                     (window_width // 2, height - 1), (width - 1, height - 1)):
            with self.subTest(x=x, y=y):
                self.assertTrue(all(abs(a - b) <= 12 for a, b in zip(pixel(x, y), corner)), pixel(x, y))

    def test_icon_labels_are_readable_in_light_and_dark_appearance(self):
        pixel = self.background_pixels()
        label_top = dmg.APP_POSITION[1] + dmg.ICON_SIZE // 2
        for center, _ in (dmg.APP_POSITION, dmg.APPLICATIONS_POSITION):
            samples = [relative_luminance(pixel(x, y)) for x in range(center - 60, center + 61, 3)
                       for y in range(label_top, label_top + 32, 2)]
            with self.subTest(icon_at=center):
                self.assertGreaterEqual(1.05 / (max(samples) + 0.05), 4.4, "white label (dark appearance)")
                self.assertGreaterEqual((min(samples) + 0.05) / 0.05, 4.4, "black label (light appearance)")


class InstallerImageTests(unittest.TestCase):
    def test_app_icon_comes_from_the_bundle_or_falls_back_to_the_repo_icon(self):
        with tempfile.TemporaryDirectory() as tmp:
            with_icon = fake_app(Path(tmp) / "a", icon=True)
            self.assertEqual(dmg.app_icon(with_icon), with_icon / "Contents" / "Resources" / "AppIcon.icns")
            self.assertEqual(dmg.app_icon(fake_app(Path(tmp) / "b")), dmg.FALLBACK_ICON)
            self.assertTrue(dmg.FALLBACK_ICON.is_file())

    def test_image_opens_as_the_laid_out_installer_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = release.make_dmg(fake_app(Path(tmp), icon=True), Path(tmp) / "out" / "Nanogram.dmg")
            self.assertEqual(sorted(path.name for path in image.parent.iterdir()), ["Nanogram.dmg"])
            mount = attach_read_only(image, Path(tmp))
            try:
                info = plistlib.loads(subprocess.run(["diskutil", "info", "-plist", str(mount)],
                                                     capture_output=True, check=True).stdout)
                self.assertEqual(info["VolumeName"], "Nanogram")
                self.assertFalse(info["WritableVolume"])
                self.assertEqual(sorted(os.listdir(mount)), [".DS_Store", ".VolumeIcon.icns", ".background",
                                                             "Applications", "Nanogram.app"])
                self.assertEqual(os.readlink(mount / "Applications"), "/Applications")
                self.assertTrue((mount / "Nanogram.app" / "Contents" / "MacOS" / "Nanogram").is_file())
                self.assertEqual((mount / ".VolumeIcon.icns").read_bytes(), b"icns")
                self.assertEqual((mount / ".background" / "background.tiff").read_bytes(),
                                 dmg.BACKGROUND.read_bytes())
                for hidden in (".background", ".VolumeIcon.icns"):
                    self.assertTrue(os.lstat(mount / hidden).st_flags & stat.UF_HIDDEN, hidden)
                finder_info = subprocess.run(["xattr", "-px", "com.apple.FinderInfo", str(mount)],
                                             capture_output=True, text=True, check=True).stdout
                self.assertEqual(bytes.fromhex(finder_info)[8] & 0x04, 0x04)

                records = {(record.filename, record.code): record.value
                           for record in dsstore.read(mount / ".DS_Store")}
                self.assertEqual(records[("Nanogram.app", "Iloc")], dsstore.iloc(*dmg.APP_POSITION))
                self.assertEqual(records[("Applications", "Iloc")], dsstore.iloc(*dmg.APPLICATIONS_POSITION))
                self.assertLess(dmg.APP_POSITION[0], dmg.APPLICATIONS_POSITION[0])
                self.assertEqual(dmg.APP_POSITION[0] + dmg.APPLICATIONS_POSITION[0], dmg.WINDOW_SIZE[0])
                window = plistlib.loads(records[(".", "bwsp")])
                self.assertEqual(window["WindowBounds"], "{{200, 260}, {640, 428}}")
                for bar in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
                    self.assertIs(window[bar], False, bar)
                view = plistlib.loads(records[(".", "icvp")])
                self.assertEqual((view["iconSize"], view["arrangeBy"], view["backgroundType"]), (128.0, "none", 2))
                alias = view["backgroundImageAlias"]
                self.assertIn(b"background.tiff", alias)
                self.assertEqual(alias[10:19], b"\x08Nanogram")
                target_cnid, = struct.unpack_from(">I", alias, 114)
                self.assertEqual(target_cnid, os.stat(mount / ".background" / "background.tiff").st_ino)
                self.assertEqual(records[(".", "vstl")], "icnv")
                self.assertNotIn((".", "pBBk"), records)
                layout = (mount / ".DS_Store").read_bytes()
                for private in ("/Users/", str(Path.home()), str(Path(tmp).resolve()), str(Path(tmp))):
                    for encoding in ("utf-8", "utf-16-be"):
                        with self.subTest(path=private, encoding=encoding):
                            self.assertNotIn(private.encode(encoding), layout)
            finally:
                subprocess.run(["hdiutil", "detach", str(mount), "-quiet"], check=False)


if __name__ == "__main__":
    unittest.main()
