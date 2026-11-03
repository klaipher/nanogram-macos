import contextlib
import io
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config, disk  # noqa: E402

DAY = 86400


def age(path: Path, seconds: float) -> None:
    stamp = time.time() - seconds
    for item in [path, *path.iterdir()] if path.is_dir() else [path]:
        os.utime(item, (stamp, stamp), follow_symlinks=False)


def hold_lock(path: Path) -> subprocess.Popen:
    code = ("import fcntl,sys,time\n"
            "h=open(sys.argv[1],'a'); fcntl.flock(h, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(60)")
    child = subprocess.Popen([sys.executable, "-c", code, str(path)], stdout=subprocess.PIPE, text=True)
    assert child.stdout.readline().strip() == "locked"
    return child


class DiskTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.cache = base / "cache"
        self.checkouts = base / "projects"
        self.cache.mkdir()
        self.checkouts.mkdir()
        patcher = mock.patch.object(config, "CACHE_DIR", self.cache)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.current = self.derived("stage2", owner="nanogram-macos-stage2")

    def checkout(self, name: str) -> Path:
        path = self.checkouts / name
        path.mkdir(exist_ok=True)
        return path

    def derived(self, suffix: str, owner: str, owner_exists: bool = True, size: int = 1000) -> Path:
        path = self.cache / (f"DerivedData-{suffix}" if suffix else "DerivedData")
        (path / "Build").mkdir(parents=True)
        (path / "Build" / "blob").write_bytes(b"x" * size)
        owner_path = self.checkouts / owner
        if owner_exists:
            owner_path.mkdir(exist_ok=True)
        with (path / "info.plist").open("wb") as handle:
            plistlib.dump({"WorkspacePath": str(owner_path / "Telegram-Mac.xcworkspace")}, handle)
        return path

    def scratch(self, name: str, size: int = 1000) -> Path:
        path = self.cache / name
        path.mkdir()
        (path / "blob").write_bytes(b"x" * size)
        return path

    def items(self):
        return disk.inventory(self.cache, self.current, checkouts=self.checkouts)

    def item(self, name: str):
        return next(i for i in self.items() if i.path.name == name)


class InventoryTests(DiskTestCase):
    def test_inventory_classifies(self):
        self.derived("runtime", owner="nanogram-macos-runtime")
        self.scratch("spm-core")
        self.scratch("swiftpm")
        self.scratch("frameworks")
        self.scratch("CompilationCache")
        self.scratch("tmp")
        self.scratch("bin")
        self.scratch("sparkle-ed25519")
        (self.cache / "build-nanogram-macos.lock").write_text("")
        kinds = {i.path.name: i.kind for i in self.items()}
        self.assertEqual(kinds, {
            "DerivedData-stage2": "derived-data", "DerivedData-runtime": "derived-data",
            "spm-core": "swiftpm-scratch", "swiftpm": "swiftpm-scratch", "frameworks": "frameworks",
            "CompilationCache": "compilation-cache", "tmp": "tmp", "bin": "other", "sparkle-ed25519": "other",
            "build-nanogram-macos.lock": "other"})
        runtime = self.item("DerivedData-runtime")
        self.assertEqual(runtime.owner, self.checkouts / "nanogram-macos-runtime")
        self.assertFalse(runtime.orphan)
        self.assertGreaterEqual(runtime.size, 1000)
        self.assertTrue(self.item("DerivedData-stage2").current)
        self.assertFalse(runtime.current)


class PruneTests(DiskTestCase):
    def test_orphan_derived_data_removed(self):
        gone = self.derived("old", owner="nanogram-macos-old", owner_exists=False)
        self.assertTrue(self.item("DerivedData-old").orphan)
        removed = disk.prune(self.items(), max_total=10**12)
        self.assertEqual([i.path for i in removed], [gone])
        self.assertFalse(gone.exists())
        self.assertTrue(self.current.exists())

    def test_derived_data_named_after_existing_checkout_is_not_orphan(self):
        self.checkout("nanogram-macos-runtime-12")
        self.derived("runtime-12", owner="moved-away", owner_exists=False)
        self.assertFalse(self.item("DerivedData-runtime-12").orphan)

    def test_locked_item_kept(self):
        stale = self.derived("runtime", owner="nanogram-macos-runtime")
        age(stale, 30 * DAY)
        child = hold_lock(self.cache / "build-nanogram-macos-runtime.lock")
        try:
            item = self.item("DerivedData-runtime")
            self.assertTrue(item.locked)
            removed = disk.prune(self.items(), max_total=0)
        finally:
            child.kill()
            child.wait()
            child.stdout.close()
        self.assertNotIn(stale, [i.path for i in removed])
        self.assertTrue(stale.exists())

    def test_current_checkout_kept(self):
        age(self.current, 30 * DAY)
        removed = disk.prune(self.items(), max_total=0)
        self.assertNotIn(self.current, [i.path for i in removed])
        self.assertTrue(self.current.exists())

    def test_stale_scratch_removed(self):
        stale = self.scratch("spm-old")
        fresh = self.scratch("spm-new")
        age(stale, 8 * DAY)
        removed = disk.prune(self.items(), max_total=10**12)
        self.assertEqual([i.path for i in removed], [stale])
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())

    def test_stale_framework_tmp_removed(self):
        tmp = self.cache / "tmp"
        old = tmp / "frameworks-1"
        new = tmp / "frameworks-2"
        old.mkdir(parents=True)
        new.mkdir()
        age(old, 7 * 3600)
        disk.prune(self.items(), max_total=10**12)
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_over_cap_evicts_lru_in_kind_order(self):
        older_dd = self.derived("runtime", owner="nanogram-macos-runtime", size=10_000)
        age(older_dd, 3 * DAY)
        scratch_a = self.scratch("spm-a", size=10_000)
        scratch_b = self.scratch("spm-b", size=10_000)
        age(scratch_a, 1 * DAY)
        age(scratch_b, 2 * DAY)
        total = sum(i.size for i in self.items())
        removed = disk.prune(self.items(), max_total=total - 1)
        self.assertEqual([i.path for i in removed], [scratch_b])
        removed = disk.prune(self.items(), max_total=sum(i.size for i in self.items()) - 1)
        self.assertEqual([i.path for i in removed], [scratch_a])
        removed = disk.prune(self.items(), max_total=sum(i.size for i in self.items()) - 1)
        self.assertEqual([i.path for i in removed], [older_dd])

    def test_compilation_cache_evicted_last(self):
        cas = self.scratch("CompilationCache", size=10_000)
        age(cas, 5 * DAY)
        spm = self.scratch("spm-a", size=10_000)
        age(spm, 1 * DAY)
        removed = disk.prune(self.items(), max_total=sum(i.size for i in self.items()) - 1)
        self.assertEqual([i.path for i in removed], [spm])
        self.assertTrue(cas.exists())

    def test_recently_used_not_evicted_over_cap(self):
        busy = self.scratch("spm-busy", size=10_000)
        age(busy, 600)
        removed = disk.prune(self.items(), max_total=0)
        self.assertEqual(removed, [])
        self.assertTrue(busy.exists())
        self.assertEqual(disk.plan_prune(self.items(), max_total=0)[busy], "keep: used in the last 2 hours")

    def test_other_never_removed(self):
        other = self.scratch("tgios-work", size=50_000)
        age(other, 90 * DAY)
        removed = disk.prune(self.items(), max_total=0)
        self.assertNotIn(other, [i.path for i in removed])
        self.assertTrue(other.exists())

    def test_sparkle_helper_is_never_listed_for_removal(self):
        helper = self.scratch("sparkle-ed25519", size=50_000)
        age(helper, 90 * DAY)
        self.assertEqual(disk.plan_prune(self.items(), max_total=0)[helper], "keep: not a build cache")
        disk.prune(self.items(), max_total=0)
        self.assertTrue(helper.exists())

    def test_prune_refuses_protected_names_whatever_their_kind(self):
        protected = self.cache / "sparkle-ed25519"
        protected.mkdir()
        item = disk.Item(protected, "swiftpm-scratch", None, 10, 0.0, False, False, False)
        with self.assertRaises(config.ConfigError):
            disk.prune([item], max_total=0)
        self.assertTrue(protected.exists())

    def test_sparkle_private_key_lives_outside_the_cache(self):
        from nanogram import sparkle
        self.assertNotIn(Path(config.CACHE_DIR).resolve(), sparkle.KEY_FILE.resolve().parents)
        self.assertNotIn(Path.home() / ".cache", sparkle.KEY_FILE.parents)

    def test_dry_run_removes_nothing(self):
        stale = self.scratch("spm-old")
        age(stale, 8 * DAY)
        orphan = self.derived("old", owner="nanogram-macos-old", owner_exists=False)
        removed = disk.prune(self.items(), max_total=0, dry_run=True)
        self.assertEqual({i.path for i in removed}, {stale, orphan})
        self.assertTrue(stale.exists())
        self.assertTrue(orphan.exists())

    def test_refuses_paths_outside_cache(self):
        with tempfile.TemporaryDirectory() as outside:
            victim = Path(outside) / "spm-x"
            victim.mkdir()
            local = self.scratch("spm-old")
            age(local, 8 * DAY)
            items = self.items() + [disk.Item(victim, "swiftpm-scratch", None, 1, 0.0, False, False, False)]
            with self.assertRaises(config.ConfigError):
                disk.prune(items, max_total=0)
            self.assertTrue(victim.exists())
            self.assertTrue(local.exists())

    def test_plan_reports_actions(self):
        stale = self.scratch("spm-old")
        age(stale, 8 * DAY)
        actions = disk.plan_prune(self.items(), max_total=10**12)
        self.assertEqual(actions[stale], "remove: unused 8 days")
        self.assertEqual(actions[self.current], "keep: current checkout")


class CleanTests(DiskTestCase):
    def setUp(self):
        super().setUp()
        self.root = self.checkout("nanogram-macos-stage2")
        (self.root / "build-output" / "apps" / "Debug-direct").mkdir(parents=True)
        (self.root / "build-output" / "apps" / "Debug-direct" / "app").write_text("x")
        (self.root / "build-output" / "keep.log").write_text("x")
        (self.current / "ModuleCache.noindex").mkdir()
        patcher = mock.patch.object(config, "DERIVED_DATA", self.current)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_clean_removes_build_and_apps(self):
        freed = disk.clean(self.root, everything=False)
        self.assertGreater(freed, 0)
        self.assertFalse((self.current / "Build").exists())
        self.assertTrue((self.current / "ModuleCache.noindex").exists())
        self.assertFalse((self.root / "build-output" / "apps").exists())
        self.assertTrue((self.root / "build-output" / "keep.log").exists())

    def test_clean_all_removes_derived_data_and_apps(self):
        disk.clean(self.root, everything=True)
        self.assertFalse(self.current.exists())
        self.assertFalse((self.root / "build-output" / "apps").exists())

    def test_clean_refuses_derived_data_outside_the_cache(self):
        outside = Path(self.tmp.name) / "elsewhere" / "DerivedData"
        (outside / "Build").mkdir(parents=True)
        for target in (outside, self.cache / "Projects", self.cache, self.cache / ".." / "DerivedData-x"):
            target.mkdir(parents=True, exist_ok=True)
            with self.subTest(target=target), mock.patch.object(config, "DERIVED_DATA", target):
                for everything in (True, False):
                    with self.assertRaises(config.ConfigError):
                        disk.clean(self.root, everything=everything)
                self.assertTrue(target.exists())
        self.assertTrue((outside / "Build").exists())
        self.assertTrue((self.root / "build-output" / "apps").exists())

    def test_clean_main_refuses_before_measuring(self):
        outside = Path(self.tmp.name) / "elsewhere"
        outside.mkdir()
        with mock.patch.object(config, "DERIVED_DATA", outside), mock.patch.object(config, "ROOT", self.root), \
                mock.patch.object(disk, "disk_usage") as usage, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(disk.main(["clean", "--all"]), 1)
        usage.assert_not_called()

    def test_clean_refuses_a_symlink_out_of_the_cache(self):
        outside = Path(self.tmp.name) / "elsewhere"
        (outside / "Build").mkdir(parents=True)
        link = self.cache / "DerivedData-link"
        link.symlink_to(outside)
        with mock.patch.object(config, "DERIVED_DATA", link), self.assertRaises(config.ConfigError):
            disk.clean(self.root, everything=True)
        self.assertTrue((outside / "Build").exists())

    def test_clean_main_holds_the_lock_exclusively(self):
        with mock.patch.object(config, "ROOT", self.root), mock.patch.object(disk.checkoutlock, "hold") as hold, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(disk.main(["clean"]), 0)
        self.assertFalse((self.current / "Build").exists())
        self.assertTrue(hold.call_args.kwargs["exclusive"])


if __name__ == "__main__":
    unittest.main()
