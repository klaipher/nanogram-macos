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


GB = 1024 ** 3


class OrphanBazelServers(unittest.TestCase):
    def base(self, **kw):
        base = {"path": "/b/1", "workspace": "/gone", "server_alive": True, "server_pids": [4242], "mtime": NOW - DAY, "size": 5}
        base.update(kw)
        return base

    def plan(self, bases, existing=()):
        return gc.plan_output_bases(bases, lambda p: p in existing, lambda p: True, NOW, RECENT)

    def test_deleted_workspace_with_running_server_is_planned_with_its_pid(self):
        plan = self.plan([self.base()])
        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0].action, "bazel-orphan")
        self.assertEqual(plan[0].pids, (4242,))
        self.assertEqual(plan[0].path, "/b/1")
        self.assertIn("stopped first", plan[0].reason)

    def test_existing_workspace_is_never_touched_even_with_a_server(self):
        self.assertEqual(self.plan([self.base()], existing={"/gone"}), [])

    def test_live_server_that_could_not_be_verified_keeps_the_base(self):
        self.assertEqual(self.plan([self.base(server_pids=[])]), [])
        self.assertEqual(self.plan([self.base(server_pids=None)]), [])

    def test_recent_activity_and_unmounted_volumes_keep_the_base(self):
        self.assertEqual(self.plan([self.base(mtime=NOW - 60)]), [])
        self.assertEqual(gc.plan_output_bases([self.base()], lambda p: False, lambda p: False, NOW, RECENT), [])

    def test_idle_base_without_server_is_still_a_plain_removal(self):
        plan = self.plan([self.base(server_alive=False, server_pids=[])])
        self.assertEqual([(r.action, r.pids) for r in plan], [("rmtree", ())])


class ServerProcessVerification(unittest.TestCase):
    BASE = "/Users/u/Library/Caches/bazel/_bazel_u/" + "a" * 32

    def table(self):
        return [
            (100, f"/usr/bin/java -jar /x/install/A-server.jar --output_base={self.BASE} --install_base=/x/install"),
            (101, f"/opt/homebrew/bin/bazel build //app --output_base={self.BASE}"),
            (102, f"/usr/bin/java -jar /x/A-server.jar --output_base={self.BASE}2"),
            (103, f"vim --output_base={self.BASE}"),
            (104, "/usr/bin/java -jar /x/A-server.jar --output_base=/other/" + "b" * 32),
            (105, f"grep --output_base={self.BASE}"),
        ]

    def test_only_processes_with_this_exact_output_base_that_look_like_bazel(self):
        self.assertEqual(gc.bazel_server_pids(self.BASE, self.table(), None, own_pid=1), [100, 101])

    def test_pid_from_the_pid_file_counts_when_the_command_line_matches(self):
        self.assertEqual(gc.bazel_server_pids(self.BASE, self.table(), 103, own_pid=1), [100, 101, 103])

    def test_pid_file_pid_with_a_different_command_is_ignored(self):
        self.assertEqual(gc.bazel_server_pids(self.BASE, self.table(), 104, own_pid=1), [100, 101])

    def test_own_process_is_never_a_target(self):
        self.assertEqual(gc.bazel_server_pids(self.BASE, self.table(), None, own_pid=100), [101])

    def test_prefix_of_another_base_does_not_match(self):
        self.assertFalse(gc.has_output_base(f"x --output_base={self.BASE}2", self.BASE))
        self.assertTrue(gc.has_output_base(f"x --output_base={self.BASE} y", self.BASE))
        self.assertTrue(gc.has_output_base(f"x --output_base={self.BASE}", self.BASE))

    def test_gather_uses_the_pid_file_and_the_process_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            pol = gc.Policy(json.loads(gc.POLICY_FILE.read_text()), home, "u")
            base = home / "Library/Caches/bazel/_bazel_u" / ("c" * 32)
            (base / "server").mkdir(parents=True)
            (base / "DO_NOT_BUILD_HERE").write_text("/gone/workspace")
            (base / "server/server.pid.txt").write_text(str(os.getpid()))
            table = [(os.getpid() + 7, f"java A-server.jar --output_base={base}")]
            bases = gc.gather_output_bases(pol, [], NOW, table)
            self.assertTrue(bases[0]["server_alive"])
            self.assertEqual(bases[0]["server_pids"], [os.getpid() + 7])


class StopServers(unittest.TestCase):
    BASE = "/b/" + "d" * 32

    def run_stop(self, commands, stays=(), **kw):
        alive = set(commands)
        signals = []

        def send(pid, sig):
            signals.append((pid, sig))
            if sig == gc.signal.SIGKILL or pid not in stays:
                alive.discard(pid)

        ok = gc.stop_bazel_servers(self.BASE, tuple(commands), send=send, command_of=lambda pid: commands[pid],
                                   alive=lambda pid: pid in alive, sleep=lambda s: None, term_wait=0.0, kill_wait=0.0, **kw)
        return ok, signals

    def test_sigterm_is_enough_for_a_cooperative_server(self):
        ok, signals = self.run_stop({10: f"java --output_base={self.BASE}"})
        self.assertTrue(ok)
        self.assertEqual(signals, [(10, gc.signal.SIGTERM)])

    def test_stubborn_server_gets_sigkill(self):
        ok, signals = self.run_stop({10: f"java --output_base={self.BASE}"}, stays={10})
        self.assertTrue(ok)
        self.assertEqual(signals, [(10, gc.signal.SIGTERM), (10, gc.signal.SIGKILL)])

    def test_reused_pid_with_another_command_is_not_signalled(self):
        ok, signals = self.run_stop({10: "/Applications/Xcode.app/Contents/MacOS/Xcode"})
        self.assertTrue(ok)
        self.assertEqual(signals, [])

    def test_failure_to_signal_keeps_the_base(self):
        def send(pid, sig):
            raise PermissionError()

        ok = gc.stop_bazel_servers(self.BASE, (10,), send=send, command_of=lambda pid: f"java --output_base={self.BASE}",
                                   alive=lambda pid: True, sleep=lambda s: None, term_wait=0.0, kill_wait=0.0)
        self.assertFalse(ok)

    def test_execute_does_not_delete_the_base_when_the_server_survives(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ("e" * 32)
            base.mkdir()
            removal = gc.Removal("bazel-output-base", str(base), "r", 0, "bazel-orphan", "", (os.getpid(),))
            real = gc.stop_bazel_servers
            gc.stop_bazel_servers = lambda *a, **k: False
            try:
                self.assertFalse(gc.execute(removal))
            finally:
                gc.stop_bazel_servers = real
            self.assertTrue(base.exists())
            gc.stop_bazel_servers = lambda *a, **k: True
            try:
                self.assertTrue(gc.execute(removal))
            finally:
                gc.stop_bazel_servers = real
            self.assertFalse(base.exists())


class BazelBuildDetection(unittest.TestCase):
    def test_build_like_commands_count(self):
        self.assertTrue(gc.bazel_build_running(["/opt/homebrew/bin/bazel build //x"]))
        self.assertTrue(gc.bazel_build_running(["bazelisk test //y --foo"]))
        self.assertFalse(gc.bazel_build_running(["/opt/homebrew/bin/bazel shutdown"]))
        self.assertFalse(gc.bazel_build_running(["/usr/bin/java -jar A-server.jar --output_base=/b build"]))
        self.assertFalse(gc.bazel_build_running(["vim build"]))


class DiskCachePlan(unittest.TestCase):
    def files(self, count=10, size=GB):
        return [(NOW - (count - i) * DAY, size, f"/c/cas/{i:02d}/f{i}") for i in range(count)]

    def plan(self, files, cap, free=100 * GB, floor=25 * GB, building=False, min_age=900):
        return gc.plan_disk_cache(files, cap, free, floor, building, NOW, min_age, root="/c")

    def planned(self, plan):
        return [path for r in plan for path, _, _ in r.files]

    def test_over_cap_removes_the_least_recently_used_down_to_the_cap(self):
        plan = self.plan(self.files(), cap=7 * GB)
        self.assertEqual(self.planned(plan), ["/c/cas/00/f0", "/c/cas/01/f1", "/c/cas/02/f2"])
        self.assertEqual({r.action for r in plan}, {"disk-cache-trim"})
        self.assertEqual({r.path for r in plan}, {"/c"})
        self.assertIn("cap", plan[0].reason)

    def test_under_cap_and_enough_free_space_removes_nothing(self):
        self.assertEqual(self.plan(self.files(), cap=10 * GB), [])

    def test_free_space_below_the_floor_trims_further_than_the_cap(self):
        plan = self.plan(self.files(), cap=20 * GB, free=24 * GB + GB // 2)
        self.assertEqual(len(self.planned(plan)), 1)
        self.assertIn("floor", plan[0].reason)
        plan = self.plan(self.files(), cap=20 * GB, free=22 * GB)
        self.assertEqual(len(self.planned(plan)), 3)

    def test_the_larger_of_cap_excess_and_shortfall_wins(self):
        plan = self.plan(self.files(), cap=5 * GB, free=24 * GB)
        self.assertEqual(len(self.planned(plan)), 5)
        self.assertIn("cap", plan[0].reason)

    def test_nothing_is_deleted_while_bazel_builds(self):
        self.assertEqual(self.plan(self.files(), cap=1 * GB, building=True), [])

    def test_fresh_entries_stay_even_when_the_target_is_not_reached(self):
        files = self.files(3) + [(NOW - 60, GB, "/c/cas/ff/new")]
        planned = self.planned(self.plan(files, cap=0))
        self.assertNotIn("/c/cas/ff/new", planned)
        self.assertEqual(len(planned), 3)

    def test_plan_is_cut_into_chunks_and_never_exceeds_the_cache(self):
        files = self.files(5, size=GB // 2)
        plan = gc.plan_disk_cache(files, 0, 100 * GB, 0, False, NOW, 900, chunk_bytes=GB, root="/c")
        self.assertEqual([len(r.files) for r in plan], [2, 2, 1])
        self.assertEqual(sum(r.size for r in plan), int(2.5 * GB))

    def test_floor_zero_disables_the_floor_rule(self):
        self.assertEqual(self.plan(self.files(), cap=20 * GB, free=1 * GB, floor=0), [])


class DiskCacheOnDisk(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)
        self.policy = gc.Policy(json.loads(gc.POLICY_FILE.read_text()), self.home, "u")
        self.cache = self.home / ".cache/telegram-ios/bazel-disk-cache"
        for index in range(6):
            entry = self.cache / ("cas" if index % 2 else "ac") / f"{index:02x}" / f"{index:064x}"
            entry.parent.mkdir(parents=True, exist_ok=True)
            entry.write_bytes(b"x" * 1000)
            stamp = time.time() - (10 - index) * DAY
            os.utime(entry, (stamp, stamp))
        (self.cache / "gc").mkdir()
        (self.cache / "gc/lock").write_text("keep")
        (self.cache / "cas/00").mkdir(parents=True, exist_ok=True)
        (self.cache / "cas/00/partial.tmp.1").write_bytes(b"y" * 1000)

    def test_scan_sees_entries_but_not_gc_files_or_temporary_files(self):
        files = gc.scan_disk_cache(self.cache, time.time() + 60)
        self.assertEqual(len(files), 6)
        self.assertTrue(all("/gc/" not in path and ".tmp" not in path for _, _, path in files))

    def test_scan_gives_up_when_the_deadline_passed(self):
        self.assertIsNone(gc.scan_disk_cache(self.cache, time.time() - 1, check_every=1))

    def run_trim(self, cap, dry_run=False):
        pol = gc.Policy({**self.policy.data, "caps_gb": {**self.policy.data["caps_gb"], "bazel_disk_cache": cap / GB},
                         "free_space_floor_gb": 0}, self.home, "u")
        return gc.run(pol, {"bazel-disk-cache"}, dry_run=dry_run, tmpdir=self.home / "t", quiet=True)

    def count(self):
        return len(gc.scan_disk_cache(self.cache, time.time() + 60))

    def test_run_trims_the_oldest_entries_down_to_the_cap(self):
        result = self.run_trim(3000)
        self.assertEqual(self.count(), 3)
        self.assertEqual(result["freed"], 3000)
        self.assertTrue((self.cache / "gc/lock").exists())
        self.assertTrue((self.cache / "cas/00/partial.tmp.1").exists())
        newest = self.cache / "cas" / "05" / f"{5:064x}"
        self.assertTrue(newest.exists())

    def test_dry_run_keeps_everything(self):
        result = self.run_trim(3000, dry_run=True)
        self.assertEqual(result["removed"], 1)
        self.assertEqual(self.count(), 6)

    def test_entry_used_after_the_scan_is_kept(self):
        files = gc.scan_disk_cache(self.cache, time.time() + 60)
        plan = gc.plan_disk_cache(files, 0, 100 * GB, 0, False, time.time(), 900, root=str(self.cache))
        for _, _, path in files:
            os.utime(path, None)
        for removal in plan:
            gc.execute(removal)
        self.assertEqual(self.count(), 6)

    def test_safety_accepts_only_the_disk_cache_itself(self):
        roots = gc.allowed_roots(self.policy, [], self.home / "t")
        entry = (str(self.cache / "cas/01/x"), 1, 0.0)
        ok = gc.Removal("bazel-disk-cache", str(self.cache), "r", 1, "disk-cache-trim", "", (), (entry,))
        self.assertIsNone(gc.safe_to_remove(ok, self.policy, roots))
        elsewhere = gc.Removal("bazel-disk-cache", str(self.home / "Documents"), "r", 1, "disk-cache-trim", "", (), (entry,))
        self.assertEqual(gc.safe_to_remove(elsewhere, self.policy, roots), "not the Bazel disk cache")
        escape = gc.Removal("bazel-disk-cache", str(self.cache), "r", 1, "disk-cache-trim", "", (),
                            ((str(self.home / "Documents/secret"), 1, 0.0),))
        self.assertEqual(gc.safe_to_remove(escape, self.policy, roots), "entry outside the Bazel disk cache")
        dotdot = gc.Removal("bazel-disk-cache", str(self.cache), "r", 1, "disk-cache-trim", "", (),
                            ((str(self.cache / "cas/../../x"), 1, 0.0),))
        self.assertEqual(gc.safe_to_remove(dotdot, self.policy, roots), "entry outside the Bazel disk cache")


class FreeSpaceFloor(unittest.TestCase):
    def pol(self, home, floor):
        data = json.loads(gc.POLICY_FILE.read_text())
        data["free_space_floor_gb"] = floor
        return gc.Policy(data, home, "u")

    def test_policy_has_a_floor_and_a_minimum_age(self):
        data = json.loads(gc.POLICY_FILE.read_text())
        self.assertGreaterEqual(data["free_space_floor_gb"], 10)
        self.assertGreater(data["bazel_disk_cache_min_age_minutes"], 0)

    def test_low_space_is_judged_against_the_floor(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            real = gc.free_bytes
            try:
                gc.free_bytes = lambda path: 10 * GB
                self.assertTrue(gc.low_on_space(self.pol(home, 25)))
                self.assertFalse(gc.low_on_space(self.pol(home, 5)))
                self.assertFalse(gc.low_on_space(self.pol(home, 0)))
            finally:
                gc.free_bytes = real

    def test_auto_skips_its_throttle_only_when_space_is_low(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            pol = self.pol(home, 25)
            state = pol.path("state_file")
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({"last_run": time.time()}))
            calls = []
            real_run, real_free = gc.run, gc.free_bytes
            gc.run = lambda *a, **k: calls.append(1) or {"removed": 0, "freed": 0, "refused": 0, "lines": []}
            try:
                gc.free_bytes = lambda path: 100 * GB
                gc.auto(pol, None)
                self.assertEqual(calls, [])
                gc.free_bytes = lambda path: 10 * GB
                gc.auto(pol, None)
                self.assertEqual(calls, [1])
            finally:
                gc.run, gc.free_bytes = real_run, real_free

    def test_free_bytes_of_a_missing_path_uses_its_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertGreater(gc.free_bytes(Path(tmp) / "a" / "b"), 0)
