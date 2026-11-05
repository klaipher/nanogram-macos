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

    def test_running_server_of_a_gone_workspace_is_stopped_then_removed(self):
        plan = self.plan([self.base(server_alive=True, pid=4242)])
        self.assertEqual([(r.action, r.pid) for r in plan], [("stop-and-rmtree", 4242)])

    def test_running_server_without_a_pid_is_kept(self):
        self.assertEqual(self.plan([self.base(server_alive=True)]), [])

    def test_existing_workspace_with_running_server_never_removed(self):
        plan = gc.plan_output_bases([self.base(server_alive=True, pid=1, mtime=NOW - 30 * DAY)], lambda p: True,
                                    lambda p: True, NOW, RECENT, 3)
        self.assertEqual(plan, [])

    def unused(self, **kw):
        return gc.plan_output_bases([self.base(workspace="/ws/A", **kw)], lambda p: True, lambda p: True, NOW, RECENT,
                                    3, kw.pop("keep", frozenset()))

    def test_unused_base_of_an_existing_worktree_is_removed_after_n_days(self):
        self.assertEqual(len(self.unused(mtime=NOW - 4 * DAY)), 1)
        self.assertEqual(self.unused(mtime=NOW - 2 * DAY), [])

    def test_unused_rule_is_off_without_a_setting_and_spares_the_current_checkout(self):
        old = self.base(workspace="/ws/A", mtime=NOW - 9 * DAY)
        self.assertEqual(gc.plan_output_bases([old], lambda p: True, lambda p: True, NOW, RECENT), [])
        self.assertEqual(gc.plan_output_bases([old], lambda p: True, lambda p: True, NOW, RECENT, 3,
                                              frozenset({"/ws/A"})), [])

    def test_unknown_workspace_kept(self):
        self.assertEqual(self.plan([self.base(workspace=None)]), [])

    def test_gone_workspace_is_removed_even_when_recent(self):
        self.assertEqual(len(self.plan([self.base(mtime=NOW - 60)])), 1)

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

    def test_ide_gate_still_available_to_callers(self):
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
        plan = gc.plan_spm_build(entries, NOW, 7, RECENT, {"/r/s/.build/x"})
        self.assertEqual([r.path for r in plan], ["/r/p/.build"])

    def test_only_the_directory_in_use_is_skipped(self):
        entries = [{"path": "/r/p/.build", "last_used": NOW - 10 * DAY, "size": 1},
                   {"path": "/r/q/.build", "last_used": NOW - 10 * DAY, "size": 1}]
        plan = gc.plan_spm_build(entries, NOW, 7, RECENT, set(), {"/r/p/.build"})
        self.assertEqual([r.path for r in plan], ["/r/q/.build"])


class SpmScratch(unittest.TestCase):
    def test_stale_then_lru(self):
        g = 1024 ** 3
        entries = [{"path": "/s/a", "last_used": NOW - 10 * DAY, "size": g},
                   {"path": "/s/b", "last_used": NOW - 3 * DAY, "size": 4 * g},
                   {"path": "/s/c", "last_used": NOW - 2 * DAY, "size": 4 * g},
                   {"path": "/s/d", "last_used": NOW - 60, "size": 4 * g}]
        plan = gc.plan_spm_scratch(entries, NOW, 7, 6 * g, RECENT, set())
        self.assertEqual([r.path for r in plan], ["/s/a", "/s/b", "/s/c"])

    def test_only_the_directory_in_use_is_skipped(self):
        entries = [{"path": "/s/a", "last_used": NOW - 10 * DAY, "size": 1},
                   {"path": "/s/b", "last_used": NOW - 10 * DAY, "size": 1}]
        plan = gc.plan_spm_scratch(entries, NOW, 7, 0, RECENT, {"/s/a"})
        self.assertEqual([r.path for r in plan], ["/s/b"])

    def test_orphan_goes_first_and_busy_orphan_stays(self):
        entries = [{"path": "/s/a", "last_used": NOW - 3 * 3600, "size": 5, "orphan": True},
                   {"path": "/s/b", "last_used": NOW - 3 * 3600, "size": 5, "orphan": True},
                   {"path": "/s/c", "last_used": NOW - 3 * 3600, "size": 5}]
        plan = gc.plan_spm_scratch(entries, NOW, 7, 100, RECENT, {"/s/b"})
        self.assertEqual([(r.path, r.reason) for r in plan], [("/s/a", "its checkout no longer exists")])


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
            data.pop("bazel_output_base_unused_days", None)
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


class CompilationCache(unittest.TestCase):
    def test_whole_unit_only_when_over_cap_and_idle(self):
        self.assertEqual(gc.plan_module_cache("/c", 11, 10, False, "compilation-cache")[0].category, "compilation-cache")
        self.assertEqual(gc.plan_module_cache("/c", 11, 10, True, "compilation-cache"), [])
        self.assertEqual(gc.plan_module_cache("/c", 9, 10, False, "compilation-cache"), [])


class DiskCacheTrim(unittest.TestCase):
    def blobs(self, count, size=10, age=DAY):
        return [(f"/c/cas/{i}", NOW - age - i, size) for i in range(count)]

    def plan(self, files, cap, busy=False):
        return gc.plan_bazel_disk_cache(files, "/c", NOW, cap, RECENT, busy)

    def test_under_cap_nothing(self):
        self.assertEqual(self.plan(self.blobs(5), 100), [])

    def test_trims_oldest_first_down_to_ninety_percent(self):
        files = self.blobs(10)               # 100 bytes, blob 9 is the oldest
        (removal,) = self.plan(files, 90)    # goal 81: two blobs go
        self.assertEqual(removal.action, "trim")
        self.assertEqual(removal.files, ("/c/cas/9", "/c/cas/8"))

    def test_recently_touched_blobs_stay(self):
        files = self.blobs(4, age=60)
        self.assertEqual(self.plan(files, 10), [])

    def test_waits_for_bazels_own_gc(self):
        self.assertEqual(self.plan(self.blobs(10), 10, busy=True), [])

    def test_trim_deletes_only_blobs_under_ac_and_cas(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve() / "cache"
            (root / "cas/ab").mkdir(parents=True)
            (root / "gc").mkdir()
            blob, other = root / "cas/ab/blob", root / "gc/lock"
            blob.write_text("12345")
            other.write_text("x")
            count, freed = gc.trim_files(root, (str(blob), str(other), str(root / "cas/missing")))
            self.assertEqual((count, freed), (1, 5))
            self.assertFalse(blob.exists())
            self.assertTrue(other.exists())

    def test_scan_lists_blobs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ac/00").mkdir(parents=True)
            (root / "ac/00/x").write_text("abc")
            files = gc.scan_bazel_disk_cache(root, time.time() + 60)
            self.assertEqual([(Path(p).name, s) for p, _, s in files], [("x", 3)])
            self.assertIsNone(gc.scan_bazel_disk_cache(root, time.time() - 1))

    def test_trim_target_must_be_the_disk_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            pol = policy(home)
            ok = gc.Removal("bazel-disk-cache", str(pol.path("bazel_disk_cache")), "r", 0, "trim")
            bad = gc.Removal("bazel-disk-cache", str(home / "elsewhere"), "r", 0, "trim")
            self.assertIsNone(gc.safe_to_remove(ok, pol, []))
            self.assertEqual(gc.safe_to_remove(bad, pol, []), "not the Bazel disk cache")


class StopServer(unittest.TestCase):
    def test_refuses_a_process_that_is_not_the_bazel_server_of_that_base(self):
        import subprocess
        child = subprocess.Popen(["sleep", "30"])
        try:
            self.assertFalse(gc.stop_bazel_server(child.pid, "/some/base"))
            self.assertIsNone(child.poll())
        finally:
            child.kill()
            child.wait()

    def test_a_missing_process_counts_as_stopped(self):
        self.assertTrue(gc.stop_bazel_server(2 ** 22 - 3, "/some/base"))

    def test_stops_a_matching_server(self):
        import subprocess
        base = "/tmp/fake-bazel-base-for-test"
        child = subprocess.Popen(["bash", "-c", f"exec -a 'bazel(test) --output_base={base}' sleep 30"])
        try:
            time.sleep(0.5)
            if "bazel(" not in gc.bazel_server_command(child.pid):
                self.skipTest("cannot set argv[0] here")
            self.assertTrue(gc.stop_bazel_server(child.pid, base))
        finally:
            child.kill()
            child.wait()


class CacheRoot(unittest.TestCase):
    def entry(self, path, kind="spm-scratch", age=DAY, size=1, orphan=False):
        return {"path": path, "kind": kind, "last_used": NOW - age, "size": size, "orphan": orphan}

    def plan(self, entries, fixed=0, cap=100, busy=(), current=()):
        return gc.plan_cache_root(entries, fixed, NOW, 14, cap, RECENT, set(busy), set(current))

    def test_orphan_derived_data_goes_at_once(self):
        plan = self.plan([self.entry("/r/DerivedData-gone", "derived-data", age=3 * 3600, orphan=True)])
        self.assertEqual([r.path for r in plan], ["/r/DerivedData-gone"])

    def test_busy_and_current_are_never_chosen(self):
        entries = [self.entry("/r/DerivedData-a", "derived-data", age=30 * DAY, orphan=True),
                   self.entry("/r/DerivedData-b", "derived-data", age=30 * DAY)]
        self.assertEqual(self.plan(entries, busy={"/r/DerivedData-a"}, current={"/r/DerivedData-b"}), [])

    def test_unused_for_days_goes_even_when_under_the_cap(self):
        plan = self.plan([self.entry("/r/DerivedData-old", "derived-data", age=20 * DAY)])
        self.assertEqual(len(plan), 1)

    def test_total_cap_takes_scratch_before_derived_data_least_recently_used_first(self):
        entries = [self.entry("/r/DerivedData-x", "derived-data", age=5 * DAY, size=30),
                   self.entry("/r/spm-a-P", age=2 * DAY, size=30),
                   self.entry("/r/spm-b-P", age=4 * DAY, size=30)]
        plan = self.plan(entries, fixed=30, cap=100)   # 120 -> remove 20+
        self.assertEqual([r.path for r in plan], ["/r/spm-b-P"])
        plan = self.plan(entries, fixed=30, cap=70)
        self.assertEqual([r.path for r in plan], ["/r/spm-b-P", "/r/spm-a-P"])

    def test_recent_entries_survive_the_cap(self):
        entries = [self.entry("/r/spm-a-P", age=60, size=500)]
        self.assertEqual(self.plan(entries, cap=100), [])

    def test_names(self):
        self.assertEqual(gc.derived_data_name("nanogram-macos"), "DerivedData")
        self.assertEqual(gc.derived_data_name("nanogram-macos-stage2"), "DerivedData-stage2")
        self.assertEqual(gc.derived_data_name("mac-integ"), "DerivedData-mac-integ")
        self.assertEqual(gc.scratch_owner("spm-mac-integ-ChatUI", "spm-", {"mac", "mac-integ"}), "mac-integ")
        self.assertEqual(gc.scratch_owner("spm-mac-integ-ChatUI", "spm-", {"other"}), None)


class InUse(unittest.TestCase):
    def test_path_cwd_and_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = Path(tmp) / "x.lock"
            lock.write_text("")
            self.assertTrue(gc.in_use("/a/b", ["swift build --scratch-path /a/b"], set()))
            self.assertTrue(gc.in_use("/a/b", [], {"/a/b/sub"}))
            self.assertFalse(gc.in_use("/a/b", ["swift build --scratch-path /a/c"], {"/a/c"}, (lock,)))
            fd = os.open(lock, os.O_RDONLY)
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_SH)      # tg build holds its checkout lock shared
            try:
                self.assertTrue(gc.in_use("/a/b", [], set(), (lock,)))
            finally:
                os.close(fd)


class Sizes(unittest.TestCase):
    def test_remembered_between_runs_and_expires(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "d"
            target.mkdir()
            (target / "f").write_bytes(b"x" * 5000)
            store = Path(tmp) / "sizes.json"
            first = gc.Sizes(store)
            size = first.get(target, 1.0, NOW)
            self.assertGreater(size, 0)
            first.save()
            second = gc.Sizes(store)
            self.assertEqual(second.cached(target, 1.0, NOW + 60), size)
            self.assertIsNone(second.cached(target, 2.0, NOW + 60))
            self.assertIsNone(second.cached(target, 1.0, NOW + gc.Sizes.MAX_AGE + 1))
            self.assertEqual(second.get(target, 5.0, NOW, measure=False), 0)

    def test_unremovable_is_remembered(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "sizes.json"
            first = gc.Sizes(store)
            first.mark_unremovable("/t/instruments-1.ktrace")
            first.save()
            self.assertIn("/t/instruments-1.ktrace", gc.Sizes(store).unremovable)


class Guard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)
        self.pol = policy(self.home)
        (self.home / ".cache/nanogram-macos").mkdir(parents=True)

    def run_guard(self, free):
        from unittest import mock
        with mock.patch.object(gc, "free_gb", return_value=free), mock.patch.object(gc, "run") as run, \
                mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TG_ALLOW_LOW_DISK", None)
            run.return_value = {"removed": 0, "freed": 0, "refused": 0, "lines": []}
            code = gc.guard(self.pol, self.home)
            return code, run

    def test_plenty_of_space_runs_the_hard_caps_only(self):
        code, run = self.run_guard(200)
        self.assertEqual(code, 0)
        self.assertEqual(run.call_args.args[1], set(gc.GUARD_CATEGORIES))
        self.assertEqual(run.call_args.kwargs["budget"], 60)

    def test_below_soft_runs_every_rule_with_the_longer_budget(self):
        code, run = self.run_guard(40)
        self.assertEqual(code, 0)
        self.assertIn("worktree", run.call_args.args[1])
        self.assertNotIn("simulator", run.call_args.args[1])
        self.assertEqual(run.call_args.kwargs["budget"], 180)

    def test_below_hard_refuses_unless_overridden(self):
        from unittest import mock
        code, _ = self.run_guard(10)
        self.assertEqual(code, 1)
        with mock.patch.object(gc, "free_gb", return_value=10), mock.patch.object(gc, "run") as run, \
                mock.patch.dict(os.environ, {"TG_ALLOW_LOW_DISK": "1"}):
            run.return_value = {"removed": 0, "freed": 0, "refused": 0, "lines": []}
            self.assertEqual(gc.guard(self.pol, self.home), 0)


class RunIntegration(unittest.TestCase):
    """A real run() over a fake home: orphan scratch and DerivedData of a deleted checkout go, the live one stays."""

    def test_orphans_removed_live_checkout_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            repo = home / "Projects/nanogram-macos"
            (repo / ".git").mkdir(parents=True)
            cache = home / ".cache/nanogram-macos"
            for name in ("spm-nanogram-macos-Pkg", "spm-deleted-wt-Pkg", "DerivedData", "DerivedData-deleted-wt", "frameworks"):
                (cache / name).mkdir(parents=True)
                (cache / name / "f").write_text("x")
            old = time.time() - 5 * 3600
            for name in ("spm-deleted-wt-Pkg", "DerivedData-deleted-wt"):
                os.utime(cache / name / "f", (old, old))
                os.utime(cache / name, (old, old))
            data = json.loads(gc.POLICY_FILE.read_text())
            data["repos"] = [str(repo)]
            pol = gc.Policy(data, home, "u")
            from unittest import mock
            with mock.patch.object(gc, "known_checkouts", return_value={"nanogram-macos"}), \
                    mock.patch.object(gc, "process_commands", return_value=[]), \
                    mock.patch.object(gc, "process_cwds", return_value=set()):
                result = gc.run(pol, {"spm-scratch", "cache-root"}, dry_run=False, repo=repo, tmpdir=home / "t", quiet=True)
            self.assertFalse((cache / "spm-deleted-wt-Pkg").exists())
            self.assertFalse((cache / "DerivedData-deleted-wt").exists())
            self.assertTrue((cache / "spm-nanogram-macos-Pkg").exists())
            self.assertTrue((cache / "DerivedData").exists())
            self.assertTrue((cache / "frameworks").exists())
            self.assertEqual(result["removed"], 2)

    def test_unknown_checkout_list_deletes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            cache = home / ".cache/nanogram-macos"
            (cache / "spm-x-Pkg").mkdir(parents=True)
            old = time.time() - 9 * 3600
            os.utime(cache / "spm-x-Pkg", (old, old))
            pol = gc.Policy(json.loads(gc.POLICY_FILE.read_text()), home, "u")
            from unittest import mock
            with mock.patch.object(gc, "known_checkouts", return_value=None), \
                    mock.patch.object(gc, "process_commands", return_value=[]), \
                    mock.patch.object(gc, "process_cwds", return_value=set()):
                gc.run(pol, {"spm-scratch", "cache-root"}, dry_run=False, repo=None, tmpdir=home / "t", quiet=True)
            self.assertTrue((cache / "spm-x-Pkg").exists())


class PolicyKeys(unittest.TestCase):
    def test_new_keys(self):
        data = json.loads(gc.POLICY_FILE.read_text())
        self.assertLess(data["free_space_gb"]["hard"], data["free_space_gb"]["soft"])
        self.assertEqual(data["bazel_max_idle_secs"], 1800)
        self.assertGreaterEqual(data["bazel_output_base_unused_days"], 1)
        self.assertEqual(data["caps_gb"]["compilation_cache"] % 2, 0)
        self.assertTrue(set(gc.GUARD_CATEGORIES) <= set(gc.CATEGORIES))


if __name__ == "__main__":
    unittest.main()
