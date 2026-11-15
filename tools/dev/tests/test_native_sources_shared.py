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

    def test_libopus_script_builds_the_core_submodule_with_the_shared_options(self):
        text = read(ROOT / "core-xprojects/libopus/libopus/build.sh")
        self.assertIn("submodules/telegram-ios/third-party/opus/opus", text)
        self.assertIn("opus-cmake-args.sh", text)
        self.assertIn('COMMON_ARGS="$OPUS_COMMON_ARGS"', text)
        self.assertNotIn("opus-1.6.1.tar.gz", text)
        self.assertNotIn("shasum -a 256 -c", text)
        self.assertNotIn("curl", text)

    def test_framework_inputs_fingerprint_the_core_sources(self):
        text = read(ROOT / "scripts/framework-inputs.sh")
        body = text.split("framework_source_roots()", 1)[1].split("\n}\n", 1)[0]
        self.assertIn(f'libvpx)\n            echo "$1/{CORE}/libvpx/libvpx"', body)
        self.assertIn(f'libopus)\n            echo "$1/{CORE}/opus/opus"', body)
        self.assertNotIn("opus-1.6.1.tar.gz", body)
        self.assertIn(f'boringssl)\n            echo "$1/{CORE}/boringssl/src"', body)

    def test_libwebp_builds_from_the_core_copy(self):
        script = read(ROOT / "core-xprojects/libwebp/libwebp/build-cmake.sh")
        self.assertIn(f"{CORE.removeprefix('submodules/telegram-ios/')}/webp/libwebp", script)
        self.assertFalse(list((ROOT / "core-xprojects/libwebp").glob("libwebp-*.tar.gz")))
        body = read(ROOT / "scripts/framework-inputs.sh").split("framework_source_roots()", 1)[1].split("\n}\n", 1)[0]
        self.assertIn(f'libwebp)\n            echo "$1/{CORE}/webp/libwebp"', body)
        self.assertNotIn("submodules/openssl", body)

    def test_flatc_is_built_from_the_pinned_release_not_committed(self):
        text = read(ROOT / "scripts/prepare-flat-serialization.py")
        self.assertIn("flatbuffers/archive/refs/tags/v25.12.19.zip", text)
        self.assertIn("f5d4636bfc4d30c622c9ad238ce947848c2b90b10aecd387dc62cdee2584359b", text)

    def test_native_libs_probes_point_at_the_core(self):
        data = ROOT / "submodules/telegram-ios/shared/tools/native/native-libs.json"  # one file for iOS and Mac (nanogram-deps)
        if not data.is_file():
            self.skipTest("the core's shared/ submodule is not checked out")
        libs = json.loads(read(data))["libs"]
        mac_vpx = {p["file"] for p in libs["libvpx"]["probes"]["mac"]}
        mac_opus = {p["file"] for p in libs["opus"]["probes"]["mac"]}
        self.assertIn(f"{CORE}/libvpx/libvpx/CHANGELOG", mac_vpx)
        self.assertTrue(any(p.startswith("submodules/telegram-ios/") and "opus" in p for p in mac_opus), mac_opus)
        for probe in mac_vpx | mac_opus:
            self.assertNotIn("core-xprojects/libvpx/source", probe)
            self.assertNotIn("core-xprojects/libopus/opus-", probe)


if __name__ == "__main__":
    unittest.main()
