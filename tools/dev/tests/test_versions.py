"""Pinned versions of the native libraries and their build flags (stage 1 task 12).

Each test reads the version from the library's own source (archive name, version header, changelog,
meson.build, submodule commit) so a bump that misses a place fails here, not at runtime.
"""
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
CORE = ROOT / "core-xprojects"
TG_IOS = ROOT / "submodules" / "telegram-ios"


def read(path: Path) -> str:
    return Path(path).read_text(errors="replace")


def gitlink(repo: Path, path: str) -> str:
    """The commit `repo` records for the submodule at `path` (its index entry, so it works without a checkout)."""
    out = subprocess.run(["git", "-C", str(repo), "ls-files", "-s", "--", path],
                         capture_output=True, text=True, check=True).stdout.split()
    if len(out) < 2 or out[0] != "160000":
        raise AssertionError(f"{path} is not a submodule of {repo}")
    return out[1]


def is_ancestor(repo: Path, ancestor: str, commit: str = "HEAD") -> bool:
    return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, commit],
                          capture_output=True, check=False).returncode == 0


class PinnedVersionsTests(unittest.TestCase):
    def test_opus(self):
        script = read(CORE / "libopus" / "libopus" / "build.sh")
        self.assertIn('SOURCE_ARCHIVE="$SRC_DIR/opus-1.6.1.tar.gz"', script)
        self.assertTrue((CORE / "libopus" / "opus-1.6.1.tar.gz").is_file())
        self.assertFalse((CORE / "libopus" / "opus-1.3.1.tar.gz").exists())
        self.assertIn("6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1", script)

    def test_opus_built_for_speed_with_fixed_point(self):
        script = read(CORE / "libopus" / "libopus" / "build.sh")
        self.assertIn("--enable-fixed-point", script)
        self.assertRegex(script, r"CFLAGS=\"[^\"]*-O2 -DNDEBUG")
        self.assertNotIn("-Os", script)

    def test_libvpx(self):
        self.assertTrue(read(CORE / "libvpx" / "source" / "CHANGELOG").startswith("2026-08-07 v1.17.0"))

    def test_libvpx_detects_arm_extensions_at_runtime(self):
        script = read(CORE / "libvpx" / "libvpx" / "build.sh")
        self.assertIn("--enable-runtime-cpu-detect", script)
        self.assertIn('target="arm64-darwin24-gcc"', script)

    def test_openh264(self):
        script = read(CORE / "OpenH264" / "OpenH264" / "build.sh")
        self.assertIn("-b v2.7.0 ", script)
        self.assertIn("1bca62311e447fd9c39fc93de2c4b96cd5ce971c", script)

    def test_libwebp(self):
        script = read(CORE / "libwebp" / "libwebp" / "build-cmake.sh")
        self.assertIn('SOURCE_ARCHIVE="$SRC_DIR/libwebp-1.6.0.tar.gz"', script)
        self.assertIn("e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564", script)
        self.assertTrue((CORE / "libwebp" / "libwebp-1.6.0.tar.gz").is_file())
        self.assertFalse((CORE / "libwebp" / "libwebp-master.zip").exists())


if __name__ == "__main__":
    unittest.main()
