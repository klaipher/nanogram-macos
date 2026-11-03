import multiprocessing
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, frameworks, fwcache  # noqa: E402

STAMP = """schema=1
lib=wallet-engine
xcode=Xcode 27.2 Build version 27B52
deployment=15.0
archs=arm64
rust=cargo 1.91.1 (ea2d97820 2025-10-10)
input:core-xprojects/wallet-engine=2c099c1e.e3b0c44298fc
"""
RUST = "rustc 1.96.1 (abc 2026-01-01)"


def write(root: Path, rel: str, text: str = "x") -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def files_below(root: Path) -> set[str]:
    return {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()}


WALLET_FILES = (
    "core-xprojects/wallet-engine/build/libwallet_engine.a",
    "core-xprojects/wallet-engine/build/WalletEngineFFI.swift",
    "packages/WalletEngine/wallet_engineFFI.xcframework/Info.plist",
    "packages/WalletEngine/wallet_engineFFI.xcframework/macos-arm64/libwallet_engine.a",
    "packages/WalletEngine/wallet_engineFFI.xcframework/macos-arm64/Headers/wallet_engineFFI.h",
    "packages/WalletEngine/wallet_engineFFI.xcframework/macos-arm64/Headers/module.modulemap",
)


def wallet_root(root: Path) -> Path:
    for rel in WALLET_FILES:
        write(root, rel, f"content of {rel}")
    write(root, "core-xprojects/wallet-engine/build/lib/x.rlib")
    write(root, "core-xprojects/wallet-engine/build/xtask/y")
    return root


class CacheKeyTests(unittest.TestCase):
    def test_key_ignores_cargo_on_path(self):
        other = STAMP.replace("cargo 1.91.1 (ea2d97820 2025-10-10)", "cargo 1.99.1 (aaaaaaaaa 2026-09-01)")
        self.assertNotEqual(STAMP, other)
        self.assertEqual(fwcache.cache_key(STAMP, RUST), fwcache.cache_key(other, RUST))

    def test_key_changes_with_pinned_rust(self):
        self.assertNotEqual(fwcache.cache_key(STAMP, "rustc 1.96.1 (abc 2026-01-01)"),
                            fwcache.cache_key(STAMP, "rustc 1.97.0 (def 2026-03-01)"))

    def test_key_changes_with_xcode_archs_deployment(self):
        base = fwcache.cache_key(STAMP, RUST)
        for old, new in (("xcode=Xcode 27.2 Build version 27B52", "xcode=Xcode 27.3 Build version 27C10"),
                         ("archs=arm64", "archs=arm64 x86_64"),
                         ("deployment=15.0", "deployment=14.0")):
            changed = STAMP.replace(old, new)
            self.assertNotEqual(changed, STAMP)
            self.assertNotEqual(fwcache.cache_key(changed, RUST), base, old)

    def test_key_is_sha256_hex(self):
        self.assertRegex(fwcache.cache_key(STAMP, RUST), r"^[0-9a-f]{64}$")


class StampTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stamps = fwcache.local_stamps(config.ROOT, fwcache.stamp_environment(), rust=RUST)

    def test_stamps_have_no_absolute_paths(self):
        stamps = self.stamps
        self.assertEqual(set(stamps), set(fwcache.UNITS))
        for unit, stamp in stamps.items():
            self.assertIn(f"lib={unit}\n", stamp)
            self.assertNotIn(str(config.ROOT), stamp, unit)
            self.assertNotIn(str(Path.home()), stamp, unit)
            self.assertIn("archs=arm64\n", stamp)
            self.assertIn("deployment=15.0\n", stamp)

    def test_tlottie_stamp_carries_pinned_rust_and_inputs(self):
        tlottie = self.stamps["tlottie"]
        self.assertIn(f"rust={RUST}\n", tlottie)
        self.assertRegex(tlottie, r"(?m)^input:submodules/tlottie=\S+$")
        self.assertRegex(tlottie, r"(?m)^input:core-xprojects/tlottie/build.sh=[0-9a-f]{64}$")

    def test_units_are_libraries_plus_tlottie(self):
        self.assertEqual(fwcache.UNITS, tuple(frameworks.libraries()) + ("tlottie",))


class CachedFilesTests(unittest.TestCase):
    def test_extra_outputs_match_upstream_reset(self):
        text = (config.ROOT / "scripts" / "framework-inputs.sh").read_text()
        body = text.split("framework_reset_outputs()", 1)[1].split("\n}\n", 1)[0]
        targets = {t.removeprefix("$1/") for t in re.findall(r'rm -rf "([^"]+)"', body)}
        self.assertEqual(targets, set(fwcache.EXTRA_OUTPUTS.values()))

    def test_cached_files_skip_scratch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = wallet_root(Path(tmp))
            listed = {str(p) for p in fwcache.cached_files(root, "wallet-engine")}
        self.assertEqual(listed, set(WALLET_FILES))

    def test_cached_files_are_relative_and_sorted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = wallet_root(Path(tmp))
            listed = fwcache.cached_files(root, "wallet-engine")
        self.assertEqual(listed, sorted(listed))
        self.assertTrue(all(not p.is_absolute() for p in listed))

    def test_cached_files_take_only_synced_headers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "core-xprojects/webrtc/build/src/api/a.h")
            write(root, "core-xprojects/webrtc/build/src/api/a.cc")
            write(root, "core-xprojects/webrtc/build/webrtc/libmac_framework_objc_static.a")
            write(root, "core-xprojects/webrtc/build/arm64/obj/b.h")
            listed = {str(p) for p in fwcache.cached_files(root, "webrtc")}
        self.assertIn("core-xprojects/webrtc/build/src/api/a.h", listed)
        self.assertIn("core-xprojects/webrtc/build/webrtc/libmac_framework_objc_static.a", listed)
        self.assertNotIn("core-xprojects/webrtc/build/src/api/a.cc", listed)
        self.assertNotIn("core-xprojects/webrtc/build/arm64/obj/b.h", listed)

    def test_cached_files_keep_whole_include_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "core-xprojects/OpenH264/build/output/lib/libopenh264.a")
            write(root, "core-xprojects/OpenH264/build/output/include/include/wels/codec_api.h")
            write(root, "core-xprojects/OpenH264/build/output/include/include/wels/codec_def.h")
            write(root, "core-xprojects/OpenH264/build/arm64/obj.o")
            listed = {str(p) for p in fwcache.cached_files(root, "OpenH264")}
        self.assertEqual(listed, {"core-xprojects/OpenH264/build/output/lib/libopenh264.a",
                                  "core-xprojects/OpenH264/build/output/include/include/wels/codec_api.h",
                                  "core-xprojects/OpenH264/build/output/include/include/wels/codec_def.h"})

    def test_header_sources_resolve_into_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            sources = fwcache.header_sources(Path(tmp))
        self.assertIn(Path(tmp) / "core-xprojects/webrtc/build/src", sources)
        self.assertTrue(all(str(s).startswith(tmp) for s in sources))
        self.assertFalse(any("SCRIPT_DIR" in str(s) or ".." in s.parts for s in sources))

    def test_tlottie_cached_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "core-xprojects/tlottie/build/libtlottie.a")
            write(root, "core-xprojects/tlottie/build/lib/aarch64-apple-darwin/release/libtlottie.a")
            listed = [str(p) for p in fwcache.cached_files(root, "tlottie")]
        self.assertEqual(listed, ["core-xprojects/tlottie/build/libtlottie.a"])


if __name__ == "__main__":
    unittest.main()
