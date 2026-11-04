import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cachegc"))
import cachegc as gc  # noqa: E402

NOW = 1_000_000_000.0
DAY = 86400
RECENT = 7200


def policy(home: Path) -> gc.Policy:
    return gc.load_policy(home=home)


class OutputBases(unittest.TestCase):
    def base(self, **kw):
        base = {"path": "/b/1", "workspace": "/gone", "server_alive": False, "mtime": NOW - DAY, "size": 5}
        base.update(kw)
        return base

    def plan(self, bases, existing=()):
        return gc.plan_output_bases(bases, lambda p: p in existing, lambda p: True, NOW, RECENT)

    def test_missing_workspace_is_removed(self):
        self.assertEqual([r.path for r in self.plan([self.base()])], ["/b/1"])

    def test_existing_workspace_kept(self):
        self.assertEqual(self.plan([self.base()], existing={"/gone"}), [])

    def test_running_server_kept(self):
        self.assertEqual(self.plan([self.base(server_alive=True)]), [])

    def test_unknown_workspace_kept(self):
        self.assertEqual(self.plan([self.base(workspace=None)]), [])

    def test_recent_kept(self):
        self.assertEqual(self.plan([self.base(mtime=NOW - 60)]), [])

    def test_unmounted_volume_kept(self):
        plan = gc.plan_output_bases([self.base()], lambda p: False, lambda p: False, NOW, RECENT)
        self.assertEqual(plan, [])


class DerivedData(unittest.TestCase):
    def plan(self, entries, busy=(), running=False, existing=()):
        return gc.plan_derived_data(entries, lambda p: p in existing, lambda p: True, NOW, 14, RECENT, set(busy), running)

    def entry(self, **kw):
        e = {"path": "/dd/A-abc", "workspace": "/ws/A", "last_used": NOW - 20 * DAY, "size": 1}
        e.update(kw)
        return e

    def test_orphan_removed_even_when_recent_enough(self):
        self.assertEqual(len(self.plan([self.entry(last_used=NOW - 3 * DAY)])), 1)

    def test_old_but_checkout_exists_removed_by_age(self):
        self.assertEqual(len(self.plan([self.entry()], existing={"/ws/A"})), 1)

    def test_young_with_checkout_kept(self):
        self.assertEqual(self.plan([self.entry(last_used=NOW - 3 * DAY)], existing={"/ws/A"}), [])

    def test_busy_and_fresh_kept(self):
        self.assertEqual(self.plan([self.entry()], busy={"/dd/A-abc"}), [])
        self.assertEqual(self.plan([self.entry(last_used=NOW - 60)]), [])

    def test_age_rule_waits_while_build_tools_run(self):
        self.assertEqual(self.plan([self.entry()], running=True, existing={"/ws/A"}), [])


class ModuleCache(unittest.TestCase):
    def test_over_cap(self):
        self.assertEqual(len(gc.plan_module_cache("/m", 5, 3, False)), 1)
        self.assertEqual(gc.plan_module_cache("/m", 3, 3, False), [])
        self.assertEqual(gc.plan_module_cache("/m", 5, 3, True), [])


class SpmBuild(unittest.TestCase):
    def test_selection(self):
        entries = [{"path": "/r/p/.build", "last_used": NOW - 10 * DAY, "size": 1},
                   {"path": "/r/q/.build", "last_used": NOW - 1 * DAY, "size": 1},
                   {"path": "/r/s/.build", "last_used": NOW - 30 * DAY, "size": 1}]
        plan = gc.plan_spm_build(entries, NOW, 7, RECENT, {"/r/s/.build/x"}, False)
        self.assertEqual([r.path for r in plan], ["/r/p/.build"])
        self.assertEqual(gc.plan_spm_build(entries, NOW, 7, RECENT, set(), True), [])


class SpmScratch(unittest.TestCase):
    def test_stale_then_lru(self):
        g = 1024 ** 3
        entries = [{"path": "/s/a", "last_used": NOW - 10 * DAY, "size": g},
                   {"path": "/s/b", "last_used": NOW - 3 * DAY, "size": 4 * g},
                   {"path": "/s/c", "last_used": NOW - 2 * DAY, "size": 4 * g},
                   {"path": "/s/d", "last_used": NOW - 60, "size": 4 * g}]
        plan = gc.plan_spm_scratch(entries, NOW, 7, 6 * g, RECENT, set(), False)
        self.assertEqual([r.path for r in plan], ["/s/a", "/s/b", "/s/c"])

    def test_nothing_while_tools_run(self):
        entries = [{"path": "/s/a", "last_used": NOW - 10 * DAY, "size": 1}]
        self.assertEqual(gc.plan_spm_scratch(entries, NOW, 7, 0, RECENT, set(), True), [])


class Instruments(unittest.TestCase):
    def test_age_and_open_handle(self):
        files = [{"path": "/t/instruments-1.ktrace", "mtime": NOW - 7200, "size": 1},
                 {"path": "/t/instruments-2.ktrace", "mtime": NOW - 600, "size": 1},
                 {"path": "/t/instruments-3.ktrace", "mtime": NOW - 7200, "size": 1}]
        plan = gc.plan_instruments(files, NOW, 3600, {"/t/instruments-3.ktrace"})
        self.assertEqual([r.path for r in plan], ["/t/instruments-1.ktrace"])


class BuildOutput(unittest.TestCase):
    def test_released_never_listed_newest_unreleased_kept(self):
        editions = {"testflight": ["202611010001", "202611020001", "202611030001", "202611040001", "202611050001",
                                   "202611060001"], "direct": ["202611010001"]}
        released = {("testflight", "202611010001"), ("direct", "202611010001")}
        plan = gc.plan_build_output(editions, released, 3, {}, set(), "/o")
        self.assertEqual([r.path for r in plan], ["/o/testflight/202611030001", "/o/testflight/202611020001"])

    def test_released_detection(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.assertFalse(gc.is_released("direct", "202611031630", d, [], "nothing"))
            self.assertTrue(gc.is_released("direct", "202611031630", d, ["v13.1.0-202611031630"], ""))
            self.assertTrue(gc.is_released("testflight", "202611031753", d, [], "## 13.1.0 (202611031753)"))
            (d / ".released").write_text("")
            self.assertTrue(gc.is_released("testflight", "1", d, [], ""))

    def test_old_logs(self):
        files = [{"path": "/o/a.log", "mtime": NOW - 20 * DAY, "size": 1}, {"path": "/o/b.log", "mtime": NOW, "size": 1}]
        self.assertEqual([r.path for r in gc.plan_build_logs(files, NOW, 14)], ["/o/a.log"])


class Worktrees(unittest.TestCase):
    def tree(self, **kw):
        t = {"repo": "/r", "path": "/w", "merged": True, "clean": True, "locked": False, "prunable": False,
             "last_used": NOW - 30 * DAY, "is_main": False}
        t.update(kw)
        return t

    def test_merged_clean_old_removed(self):
        self.assertEqual(len(gc.plan_worktrees([self.tree()], NOW, 14, set())), 1)

    def test_kept_cases(self):
        for kw in ({"is_main": True}, {"locked": True}, {"merged": False}, {"clean": False},
                   {"last_used": NOW - DAY}):
            self.assertEqual(gc.plan_worktrees([self.tree(**kw)], NOW, 14, set()), [], kw)
        self.assertEqual(gc.plan_worktrees([self.tree()], NOW, 14, {"/w/sub"}), [])

    def test_prunable_is_pruned(self):
        plan = gc.plan_worktrees([self.tree(prunable=True, last_used=NOW)], NOW, 14, set())
        self.assertEqual(plan[0].action, "worktree-prune")


class ToolTmp(unittest.TestCase):
    def test_globs_age_in_use(self):
        entries = [{"path": "/t/frameworks-1", "last_used": NOW - 5 * DAY, "size": 1},
                   {"path": "/t/frameworks-2", "last_used": NOW - 1 * DAY, "size": 1},
                   {"path": "/t/other", "last_used": NOW - 50 * DAY, "size": 1},
                   {"path": "/t/frameworks-3", "last_used": NOW - 5 * DAY, "size": 1}]
        plan = gc.plan_tool_tmp(entries, NOW, 2, ["frameworks-*"], {"/t/frameworks-3"})
        self.assertEqual([r.path for r in plan], ["/t/frameworks-1"])


class Safety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.policy = policy(self.home)
        (self.home / ".cache/nanogram-macos/launch-home").mkdir(parents=True)
        self.roots = gc.allowed_roots(self.policy, [self.home / "repo"], self.home / "tmp")

    def tearDown(self):
        self.tmp.cleanup()

    def check(self, path, action="rmtree"):
        return gc.safe_to_remove(gc.Removal("x", str(path), "r", 0, action), self.policy, self.roots)

    def test_launch_home_and_ancestors_refused(self):
        cache = self.home / ".cache/nanogram-macos"
        self.assertIn("protected", self.check(cache / "launch-home"))
        self.assertIn("protected", self.check(cache / "launch-home/x"))
        self.assertIn("protected", self.check(cache))

    def test_sparkle_key_and_dsyms_refused(self):
        cache = self.home / ".cache/nanogram-macos"
        self.assertTrue(self.check(cache / "sparkle-ed25519"))
        self.assertTrue(self.check(self.home / "Library/Application Support/Nanogram/dsyms/1"))

    def test_outside_roots_refused(self):
        self.assertEqual(self.check(self.home / "Documents/x"), "outside the known cache and build roots")
        self.assertEqual(self.check("/etc"), "outside the known cache and build roots")

    def test_root_itself_refused(self):
        self.assertTrue(self.check(self.home / "Library/Caches/bazel/_bazel_x"))

    def test_inside_cache_allowed(self):
        self.assertIsNone(self.check(self.home / ".cache/nanogram-macos/spm-a-b"))
        self.assertIsNone(self.check(self.home / "repo/packages/P/.build"))

    def test_worktree_outside_parents_refused(self):
        self.assertTrue(self.check(self.home / "elsewhere/wt", "worktree-remove"))


class Execute(unittest.TestCase):
    def test_removes_read_only_tree_and_dry_run_keeps(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            base = home / "Library/Caches/bazel/_bazel_u" / ("a" * 32)
            (base / "sub").mkdir(parents=True)
            (base / "DO_NOT_BUILD_HERE").write_text(str(home / "deleted-ws"))
            (base / "sub/f").write_text("x")
            os.chmod(base / "sub/f", 0o444)
            os.chmod(base / "sub", 0o555)
            pol = gc.Policy(json.loads(gc.POLICY_FILE.read_text()), home, "u")
            later = time.time() + 10 * DAY
            result = gc.run(pol, {"bazel-output-base"}, dry_run=True, now=later, tmpdir=home / "t", quiet=True)
            self.assertEqual(result["removed"], 1)
            self.assertTrue(base.exists())
            gc.run(pol, {"bazel-output-base"}, dry_run=False, now=later, tmpdir=home / "t", quiet=True)
            self.assertFalse(base.exists())


class PolicyFile(unittest.TestCase):
    def test_policy_is_consistent(self):
        data = json.loads(gc.POLICY_FILE.read_text())
        self.assertEqual(data["caps_gb"]["bazel_disk_cache"], 30)
        self.assertEqual(data["bazel_disk_cache_gc"]["max_size"], "30G")
        self.assertIn("launch-home", data["protected_names"])
        self.assertGreaterEqual(data["keep_unreleased_builds"], 1)
        self.assertNotIn("schedule", json.dumps(data).replace("schedule, the", ""))


if __name__ == "__main__":
    unittest.main()


class CompilationCache(unittest.TestCase):
    def test_whole_unit_only_when_over_cap_and_idle(self):
        self.assertEqual(gc.plan_module_cache("/c", 11, 10, False, "compilation-cache")[0].category, "compilation-cache")
        self.assertEqual(gc.plan_module_cache("/c", 11, 10, True, "compilation-cache"), [])
        self.assertEqual(gc.plan_module_cache("/c", 9, 10, False, "compilation-cache"), [])
