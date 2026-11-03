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


def _store_in_child(cache_dir, root, key, queue):
    config.CACHE_DIR = Path(cache_dir)
    entry = fwcache.store(Path(root), "wallet-engine", key, STAMP)
    queue.put(str(entry.path))


def _restore_in_child(cache_dir, root, key, holding, released):
    config.CACHE_DIR = Path(cache_dir)
    with fwcache.cache_lock(fwcache.fcntl.LOCK_SH):
        holding.set()
        time.sleep(1.5)
        fwcache.restore(Path(root), "wallet-engine", fwcache.lookup(key), STAMP)
        released.set()


class StoreRestoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.cache = base / "cache"
        self.a = wallet_root(base / "a")
        self.b = base / "b"
        self.b.mkdir()
        patcher = mock.patch.object(config, "CACHE_DIR", self.cache)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def stored(self, key="k1"):
        return fwcache.store(self.a, "wallet-engine", key, STAMP)

    def test_restore_layout_is_exact(self):
        entry = self.stored()
        fwcache.restore(self.b, "wallet-engine", entry, STAMP)
        restored = files_below(self.b) - {"core-xprojects/wallet-engine/build/.framework-stamp"}
        self.assertEqual(restored, set(WALLET_FILES))
        for rel in WALLET_FILES:
            self.assertEqual((self.b / rel).read_text(), f"content of {rel}")
        self.assertEqual(sorted(os.listdir(self.b)), ["core-xprojects", "packages"])
        self.assertEqual(os.listdir(self.b / "core-xprojects"), ["wallet-engine"])
        self.assertEqual(os.listdir(self.b / "core-xprojects/wallet-engine"), ["build"])
        self.assertEqual(os.listdir(self.b / "packages/WalletEngine"), ["wallet_engineFFI.xcframework"])

    def test_restore_replaces_stale_outputs(self):
        entry = self.stored()
        write(self.b, "core-xprojects/wallet-engine/build/old.a")
        write(self.b, "packages/WalletEngine/wallet_engineFFI.xcframework/old/x.a")
        write(self.b, "packages/WalletEngine/Package.swift", "keep")
        fwcache.restore(self.b, "wallet-engine", entry, STAMP)
        self.assertFalse((self.b / "core-xprojects/wallet-engine/build/old.a").exists())
        self.assertFalse((self.b / "packages/WalletEngine/wallet_engineFFI.xcframework/old").exists())
        self.assertEqual((self.b / "packages/WalletEngine/Package.swift").read_text(), "keep")

    def test_restore_writes_local_stamp(self):
        entry = self.stored()
        fwcache.restore(self.b, "wallet-engine", entry, "local stamp\n")
        self.assertEqual((self.b / "core-xprojects/wallet-engine/build/.framework-stamp").read_text(), "local stamp\n")

    def test_lookup(self):
        self.assertIsNone(fwcache.lookup("k1"))
        entry = self.stored()
        found = fwcache.lookup("k1")
        self.assertEqual((found.key, found.unit, found.path), ("k1", "wallet-engine", entry.path))
        self.assertGreater(found.size, 0)

    def test_store_existing_key_is_noop(self):
        first = self.stored()
        second = self.stored()
        self.assertEqual(first.path, second.path)
        self.assertEqual([p.name for p in fwcache.cache_root().iterdir() if ".partial-" in p.name], [])

    def test_concurrent_store_same_key(self):
        ctx = multiprocessing.get_context("spawn")
        queue = ctx.Queue()
        children = [ctx.Process(target=_store_in_child, args=(str(self.cache), str(self.a), "k1", queue))
                    for _ in range(2)]
        for child in children:
            child.start()
        for child in children:
            child.join(60)
            self.assertEqual(child.exitcode, 0)
        paths = {queue.get(timeout=5), queue.get(timeout=5)}
        self.assertEqual(paths, {str(self.cache / "frameworks" / "k1")})
        names = [p.name for p in fwcache.cache_root().iterdir() if not p.name.startswith(".")]
        self.assertEqual(names, ["k1"])

    def _aged(self, key, age):
        entry = fwcache.store(self.a, "wallet-engine", key, STAMP)
        stamp = time.time() - age
        os.utime(entry.path / "meta.json", (stamp, stamp))
        return entry

    def test_prune_evicts_lru_but_keeps_current(self):
        oldest = self._aged("k1", 300)
        middle = self._aged("k2", 200)
        newest = self._aged("k3", 100)
        evicted = fwcache.prune(oldest.size + newest.size, keep={"k1"})
        self.assertEqual([e.key for e in evicted], ["k2"])
        self.assertTrue(oldest.path.exists())
        self.assertFalse(middle.path.exists())
        self.assertTrue(newest.path.exists())

    def test_prune_removes_stale_partials(self):
        root = fwcache.cache_root()
        root.mkdir(parents=True)
        stale = root / "x.partial-1"
        fresh = root / "y.partial-2"
        broken = root / "z"
        for path in (stale, fresh, broken):
            write(path, "tree/f")
        old = time.time() - 7200
        os.utime(stale, (old, old))
        fwcache.prune(10**12, keep=set())
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())
        self.assertFalse(broken.exists())

    def test_prune_skips_entry_being_restored(self):
        self.stored()
        ctx = multiprocessing.get_context("spawn")
        holding, released = ctx.Event(), ctx.Event()
        child = ctx.Process(target=_restore_in_child, args=(str(self.cache), str(self.b), "k1", holding, released))
        child.start()
        self.assertTrue(holding.wait(30))
        evicted = fwcache.prune(0, keep=set())
        self.assertTrue(released.is_set())
        child.join(30)
        self.assertEqual(child.exitcode, 0)
        self.assertEqual([e.key for e in evicted], ["k1"])
        self.assertTrue(set(WALLET_FILES) <= files_below(self.b))

    def test_max_bytes(self):
        with mock.patch.dict(os.environ, {"NANOGRAM_FRAMEWORK_CACHE_MAX_GB": "2"}):
            self.assertEqual(fwcache.max_bytes(), 2 * 1024**3)
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(fwcache.max_bytes(), 3 * 1024**3)


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
