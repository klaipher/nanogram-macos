"""libvpx and libopus are built from the iOS core's copies, not from vendored copies (shared-code lane, 2026-11-05).

The core submodule holds libvpx v1.17.0 (third-party/libvpx/libvpx) and the opus-1.6.1 tarball
(third-party/opus). The Mac used to carry identical copies (26 MB source tree, 10.5 MB tarball).
These tests read only repository text; nothing is built.
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT
CORE = "submodules/telegram-ios/third-party"


def read(path) -> str:
    return Path(path).read_text(errors="replace")


class SharedNativeSourcesTests(unittest.TestCase):
    def test_vendored_copies_are_gone(self):
        self.assertFalse((ROOT / "core-xprojects/libvpx/source").exists())
        self.assertFalse(list((ROOT / "core-xprojects/libopus").glob("opus-*.tar.gz")))

    def test_libvpx_script_uses_core_source_relative_to_itself(self):
        text = read(ROOT / "core-xprojects/libvpx/libvpx/build.sh")
        self.assertIn(f"{CORE}/libvpx/libvpx", text)
        self.assertIn('dirname "$0"', text)
        self.assertNotIn('SOURCE_DIR="${BUILD_DIR}source"', text)
        self.assertIn("git submodule update --init --recursive", text)

    def test_libopus_script_uses_core_tarball_and_keeps_the_hash_check(self):
        text = read(ROOT / "core-xprojects/libopus/libopus/build.sh")
        self.assertIn(f"{CORE}/opus/opus-1.6.1.tar.gz", text)
        self.assertNotIn('SOURCE_ARCHIVE="$SRC_DIR/', text)
        self.assertIn("6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1", text)
        self.assertIn("shasum -a 256 -c", text)

    def test_framework_inputs_fingerprint_the_core_sources(self):
        text = read(ROOT / "scripts/framework-inputs.sh")
        body = text.split("framework_source_roots()", 1)[1].split("\n}\n", 1)[0]
        self.assertIn(f'libvpx)\n            echo "$1/{CORE}/libvpx/libvpx"', body)
        # The tarball file only, so edits to the iOS Bazel script do not invalidate the Mac cache.
        self.assertIn(f'libopus)', body)
        self.assertIn(f'"$1/{CORE}/opus/opus-1.6.1.tar.gz"', body)

    def test_native_libs_probes_point_at_the_core(self):
        libs = json.loads(read(ROOT / "tools/dev/native/native-libs.json"))["libs"]
        mac_vpx = {p["file"] for p in libs["libvpx"]["probes"]["mac"]}
        mac_opus = {p["file"] for p in libs["opus"]["probes"]["mac"]}
        self.assertIn(f"{CORE}/libvpx/libvpx/CHANGELOG", mac_vpx)
        self.assertIn(f"{CORE}/opus/opus-*.tar.gz", mac_opus)
        for probe in mac_vpx | mac_opus:
            self.assertNotIn("core-xprojects/libvpx/source", probe)
            self.assertNotIn("core-xprojects/libopus/opus-", probe)


if __name__ == "__main__":
    unittest.main()
