import json
import os
import subprocess
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

    def test_only_our_projects_are_considered(self):
        projects = gc.load_policy().data["derived_data_projects"]
        self.assertTrue(gc.ours_derived_data("Telegram-Mac-buemmmmpuarxgheskcgddorkypsq", projects))
        self.assertFalse(gc.ours_derived_data("MyOtherApp-buemmmmpuarxgheskcgddorkypsq", projects))
        self.assertFalse(gc.ours_derived_data("Telegram-Mac-Fork-buemmmmpuarxgheskcgddorkypsq", projects))

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
            self.assertTrue(gc.is_released("testflight", "202611031320", d, [], "", "202611050000"))
            self.assertFalse(gc.is_released("testflight", "202611061200", d, [], "", "202611050000"))
            self.assertFalse(gc.is_released("testflight", "202611031320", d, [], "", ""))
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
                   {"last_used": NOW - DAY}, {"holds_builds": True}):
            self.assertEqual(gc.plan_worktrees([self.tree(**kw)], NOW, 14, set()), [], kw)
        self.assertEqual(gc.plan_worktrees([self.tree()], NOW, 14, {"/w/sub"}), [])

    def test_worktree_with_builds_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp)
            self.assertFalse(gc.holds_builds(tree))
            (tree / "build-output/testflight/202611031753").mkdir(parents=True)
            self.assertTrue(gc.holds_builds(tree))

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


class MergedOutputBases(unittest.TestCase):
    def base(self, **kw):
        base = {"path": "/b/1", "workspace": "/wt/a", "server_alive": False, "mtime": NOW - DAY, "size": 5,
                "workspace_is_worktree": True, "workspace_merged": True}
        base.update(kw)
        return base

    def plan(self, bases, cwds=()):
        return gc.plan_merged_output_bases(bases, lambda p: True, NOW, RECENT, set(cwds))

    def test_merged_idle_worktree_loses_its_output_base_at_once(self):
        plan = self.plan([self.base()])
        self.assertEqual([(r.category, r.path, r.action) for r in plan], [("bazel-output-base", "/b/1", "rmtree")])

    def test_kept_cases(self):
        for kw in ({"workspace_is_worktree": False}, {"workspace_merged": False}, {"server_alive": True},
                   {"mtime": NOW - 60}, {"workspace": None}):
            self.assertEqual(self.plan([self.base(**kw)]), [], kw)
        self.assertEqual(self.plan([self.base()], cwds={"/wt/a/sub"}), [])

    def test_missing_workspace_is_the_other_rules_job(self):
        self.assertEqual(gc.plan_merged_output_bases([self.base()], lambda p: False, NOW, RECENT, set()), [])


class CacheRootTotal(unittest.TestCase):
    G = 1024 ** 3

    def entries(self):
        return [{"path": "/c/DerivedData-a", "last_used": NOW - 10 * DAY},
                {"path": "/c/spm-b", "last_used": NOW - 5 * DAY},
                {"path": "/c/tgios-work", "last_used": NOW - 2 * DAY},
                {"path": "/c/DerivedData-new", "last_used": NOW - 60}]

    def test_oldest_first_until_under_the_cap_and_sized_lazily(self):
        asked = []

        def size_of(path, mtime):
            asked.append(path)
            return 5 * self.G

        plan = gc.plan_cache_root_total(self.entries(), 52 * self.G, 40 * self.G, NOW, RECENT, set(), False, size_of)
        self.assertEqual([r.path for r in plan], ["/c/DerivedData-a", "/c/spm-b", "/c/tgios-work"][:3])
        self.assertEqual(asked, [r.path for r in plan])
        self.assertTrue(all(r.category == "cache-root" for r in plan))

    def test_stops_when_under_the_cap(self):
        plan = gc.plan_cache_root_total(self.entries(), 44 * self.G, 40 * self.G, NOW, RECENT, set(), False,
                                        lambda p, m: 5 * self.G)
        self.assertEqual([r.path for r in plan], ["/c/DerivedData-a"])

    def test_nothing_under_the_cap_busy_locked_or_recent(self):
        size = lambda p, m: self.G  # noqa: E731
        self.assertEqual(gc.plan_cache_root_total(self.entries(), 30 * self.G, 40 * self.G, NOW, RECENT, set(), False, size), [])
        self.assertEqual(gc.plan_cache_root_total(self.entries(), 90 * self.G, 40 * self.G, NOW, RECENT, set(), True, size), [])
        plan = gc.plan_cache_root_total(self.entries(), 90 * self.G, 40 * self.G, NOW, RECENT, {"/c/DerivedData-a"}, False, size)
        self.assertNotIn("/c/DerivedData-a", [r.path for r in plan])
        self.assertNotIn("/c/DerivedData-new", [r.path for r in plan])


class SizeCaching(unittest.TestCase):
    def test_measure_is_reused_until_the_directory_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "d"
            directory.mkdir()
            (directory / "f").write_bytes(b"x" * 10000)
            cache_file = Path(tmp) / "sizes.json"
            cache = gc.SizeCache(cache_file)
            mtime = gc.newest_mtime(directory)
            self.assertIsNone(cache.lookup(str(directory), mtime))
            self.assertEqual(cache.reported(str(directory), mtime), 0)
            first = cache.measure(str(directory), mtime)
            self.assertGreater(first, 0)
            cache.save()
            again = gc.SizeCache(cache_file)
            self.assertEqual(again.lookup(str(directory), mtime), first)
            self.assertIsNone(again.lookup(str(directory), mtime + 100))

    def test_save_forgets_paths_that_are_gone(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = gc.SizeCache(Path(tmp) / "sizes.json")
            cache.data["/nonexistent/for/cachegc"] = [1.0, 5]
            cache.save()
            self.assertEqual(gc.SizeCache(Path(tmp) / "sizes.json").data, {})


class LowSpace(unittest.TestCase):
    def test_threshold_comes_from_the_policy(self):
        pol = gc.load_policy()
        self.assertGreater(pol.low_free_space_bytes, 0)
        self.assertTrue(gc.low_on_space(pol, lambda p: pol.low_free_space_bytes - 1))
        self.assertFalse(gc.low_on_space(pol, lambda p: pol.low_free_space_bytes))

    def test_zero_switches_it_off(self):
        data = json.loads(gc.POLICY_FILE.read_text())
        data["low_free_space_gb"] = 0
        self.assertFalse(gc.low_on_space(gc.Policy(data), lambda p: 0))


def git_run(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(cwd), *args], check=True,
                   capture_output=True)


class MergeState(unittest.TestCase):
    def test_worktree_merged_into_main_or_ahead_of_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp).resolve() / "main"
            main.mkdir()
            git_run(main, "init", "-q", "-b", "main")
            (main / "a").write_text("1")
            git_run(main, "add", "a")
            git_run(main, "commit", "-q", "-m", "one")
            tree = Path(tmp).resolve() / "wt"
            git_run(main, "worktree", "add", "-q", "-b", "feature", str(tree))
            self.assertEqual(gc.workspace_merge_state(str(main), ["main"]), (False, False))
            self.assertEqual(gc.workspace_merge_state(str(tree), ["main"]), (True, True))
            (tree / "b").write_text("2")
            git_run(tree, "add", "b")
            git_run(tree, "commit", "-q", "-m", "two")
            self.assertEqual(gc.workspace_merge_state(str(tree), ["main"]), (True, False))
            self.assertEqual(gc.workspace_merge_state(str(tree), ["no-such-branch"]), (True, False))

    def test_run_removes_only_the_output_base_of_a_merged_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            main = home / "repo"
            main.mkdir()
            git_run(main, "init", "-q", "-b", "main")
            (main / "a").write_text("1")
            git_run(main, "add", "a")
            git_run(main, "commit", "-q", "-m", "one")
            tree = home / "wt"
            git_run(main, "worktree", "add", "-q", "-b", "feature", str(tree))
            root = home / "Library/Caches/bazel/_bazel_u"
            merged_base, main_base = root / ("a" * 32), root / ("b" * 32)
            for base, workspace in ((merged_base, tree), (main_base, main)):
                (base / "execroot").mkdir(parents=True)
                (base / "DO_NOT_BUILD_HERE").write_text(str(workspace))
            data = json.loads(gc.POLICY_FILE.read_text())
            data["repos"] = []
            pol = gc.Policy(data, home, "u")
            later = time.time() + 10 * DAY
            result = gc.run(pol, {"bazel-output-base"}, dry_run=False, now=later, tmpdir=home / "t", quiet=True)
            self.assertEqual(result["removed"], 1)
            self.assertFalse(merged_base.exists())
            self.assertTrue(main_base.exists())
            self.assertTrue(tree.exists())


class PolicyKeys(unittest.TestCase):
    def test_low_space_and_cache_root_keys(self):
        data = json.loads(gc.POLICY_FILE.read_text())
        self.assertEqual(data["low_free_space_gb"], 60)
        self.assertLess(data["max_age_days"]["worktree_merged_low_space"], data["max_age_days"]["worktree_merged"])
        self.assertGreater(data["auto"]["low_space_time_budget_seconds"], data["auto"]["time_budget_seconds"])
        self.assertIn("cache-root", gc.CATEGORIES)
        self.assertGreater(data["caps_gb"]["cache_root_total"], data["caps_gb"]["spm_scratch_total"])


class PolicyFile(unittest.TestCase):
    def test_policy_is_consistent(self):
        data = json.loads(gc.POLICY_FILE.read_text())
        self.assertEqual(data["caps_gb"]["bazel_disk_cache"], 20)
        self.assertEqual(data["bazel_disk_cache_gc"]["max_size"], "20G")
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
