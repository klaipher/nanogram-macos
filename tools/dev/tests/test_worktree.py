import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worktree"))
import worktree as wt  # noqa: E402

gc = wt.gc


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True,
                          env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@t"}).stdout


class Fixture(unittest.TestCase):
    flavor = "ios"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.main = self.home / "Projects" / "nanogram"
        self.main.mkdir(parents=True)
        git(self.main, "init", "-q", "-b", "main")
        (self.main / "README").write_text("x")
        git(self.main, "add", ".")
        git(self.main, "commit", "-q", "-m", "first")
        self.wt_root = self.home / "Projects" / "wt"
        data = json.loads(gc.POLICY_FILE.read_text())
        self.policy = gc.Policy(data, self.home, "u")
        patches = [mock.patch.dict(os.environ, {"NANOGRAM_WORKTREE_ROOT": str(self.wt_root)}),
                   mock.patch.object(gc, "load_policy", return_value=self.policy),
                   mock.patch.object(gc, "process_commands", return_value=[]),
                   mock.patch.object(gc, "process_cwds", return_value=set())]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.out = []

    def say(self, line):
        self.out.append(line)

    def add(self, name="a", **kw):
        return wt.add(self.main, self.flavor, name, out=self.say, **kw)

    def remove(self, name="a", force=False):
        return wt.remove(self.main, self.flavor, name, force, out=self.say)


class AddIos(Fixture):
    def test_creates_branch_worktree_and_links_configuration(self):
        (self.main / "build-system").mkdir()
        (self.main / "build-system/dev-configuration.json").write_text("{}")
        (self.main / "user.bazelrc").write_text("# mine")
        path = self.add()
        self.assertEqual(path, self.wt_root.resolve() / "ios-a")
        self.assertEqual(git(path, "rev-parse", "--abbrev-ref", "HEAD").strip(), "night/a")
        self.assertTrue((path / "user.bazelrc").is_symlink())
        self.assertEqual((path / "build-system/dev-configuration.json").resolve(),
                         (self.main / "build-system/dev-configuration.json").resolve())
        self.assertTrue(any("Bazel output base" in line for line in self.out))

    def test_branch_and_ref_options(self):
        git(self.main, "branch", "base")
        path = self.add("b", branch="feature/x", ref="base")
        self.assertEqual(git(path, "rev-parse", "--abbrev-ref", "HEAD").strip(), "feature/x")

    def test_existing_path_and_bad_name_are_refused(self):
        self.add()
        with self.assertRaises(wt.WorktreeError):
            self.add()
        with self.assertRaises(wt.WorktreeError):
            wt.target_path("ios", "../x")

    def test_existing_branch_is_reused_but_not_with_from(self):
        git(self.main, "branch", "night/c")
        self.add("c")
        git(self.main, "branch", "night/d")
        with self.assertRaises(wt.WorktreeError):
            self.add("d", ref="main")


class AddMac(Fixture):
    flavor = "mac"

    def test_runs_the_tg_steps_in_the_worktree_and_borrows_submodule_objects(self):
        sub = self.home / "sub-origin"
        sub.mkdir()
        git(sub, "init", "-q", "-b", "main")
        (sub / "f").write_text("1")
        git(sub, "add", ".")
        git(sub, "commit", "-q", "-m", "s")
        subprocess.run(["git", "-C", str(self.main), "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                        str(sub), "submodules/s"], check=True, capture_output=True)
        git(self.main, "commit", "-q", "-m", "sub")
        steps = []
        env = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always"}
        with mock.patch.dict(os.environ, env):
            path = self.add(run_tg=lambda tree, step: steps.append((tree, step)))
        self.assertEqual([s for _, s in steps], list(wt.MAC_TG_STEPS))
        self.assertTrue(all(t == path for t, _ in steps))
        self.assertTrue((path / "submodules/s/f").is_file())
        alternates = Path(git(path / "submodules/s", "rev-parse", "--git-dir").strip())
        alternates = (path / "submodules/s" / alternates) if not alternates.is_absolute() else alternates
        self.assertTrue((alternates / "objects/info/alternates").is_file())
        main_module = self.main / ".git/modules/submodules/s"
        self.assertEqual(git(main_module, "config", "extensions.preciousObjects").strip(), "true")
        self.assertTrue(any("DerivedData-mac-a" in line for line in self.out))

    def test_a_failing_step_is_reported(self):
        def boom(tree, step):
            raise wt.WorktreeError("tg frameworks failed")
        with self.assertRaises(wt.WorktreeError):
            self.add(run_tg=boom)
        self.assertTrue(any("setup stopped" in line for line in self.out))


class RemoveIos(Fixture):
    def make(self, name="a"):
        path = self.add(name)
        git(path, "config", "user.email", "t@t")
        return path

    def test_clean_worktree_with_its_output_base(self):
        path = self.make()
        base = self.home / "Library/Caches/bazel/_bazel_u" / ("a" * 32)
        (base / "x").mkdir(parents=True)
        (base / "DO_NOT_BUILD_HERE").write_text(str(path))
        other = self.home / "Library/Caches/bazel/_bazel_u" / ("b" * 32)
        other.mkdir()
        (other / "DO_NOT_BUILD_HERE").write_text("/somewhere/else")
        # the commit made on main is on no remote either, so the new branch has "unpushed" commits: use --force
        self.remove(force=True)
        self.assertFalse(path.exists())
        self.assertFalse(base.exists())
        self.assertTrue(other.exists())
        self.assertNotIn(path, wt.worktree_list(self.main))

    def test_dirty_and_unpushed_are_refused_and_force_overrides(self):
        path = self.make()
        with self.assertRaises(wt.WorktreeError) as raised:   # unpushed (no remotes at all)
            self.remove()
        self.assertIn("on no remote", str(raised.exception))
        git(self.main, "remote", "add", "origin", str(self.main))
        git(self.main, "update-ref", "refs/remotes/origin/main", "HEAD")
        (path / "new.txt").write_text("x")
        with self.assertRaises(wt.WorktreeError) as raised:
            self.remove()
        self.assertIn("uncommitted", str(raised.exception))
        self.remove(force=True)
        self.assertFalse(path.exists())

    def test_clean_pushed_worktree_goes_without_force(self):
        path = self.make()
        git(self.main, "remote", "add", "origin", str(self.main))
        git(self.main, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.remove()
        self.assertFalse(path.exists())

    def test_release_archives_are_never_removed_even_with_force(self):
        path = self.make()
        (path / "build-output/testflight/202611050001").mkdir(parents=True)
        with self.assertRaises(wt.WorktreeError) as raised:
            self.remove(force=True)
        self.assertIn("release archives", str(raised.exception))
        self.assertTrue(path.exists())

    def test_running_build_lock_and_processes_refuse(self):
        import fcntl
        path = self.make()
        cache = self.policy.path("cache_root")
        cache.mkdir(parents=True)
        with open(cache / "build-ios-a.lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_SH)
            with self.assertRaises(wt.WorktreeError) as raised:
                self.remove(force=True)
            self.assertIn("build lock", str(raised.exception))
        with mock.patch.object(gc, "process_cwds", return_value={str(path / "sub")}):
            with self.assertRaises(wt.WorktreeError) as raised:
                self.remove(force=True)
            self.assertIn("in use", str(raised.exception))
        self.assertTrue(path.exists())

    def test_main_checkout_and_strangers_are_refused(self):
        with self.assertRaises(wt.WorktreeError):
            self.remove("nope")


class RemoveMac(Fixture):
    flavor = "mac"

    def test_removes_this_checkouts_caches_and_nothing_else(self):
        path = self.add("integ", run_tg=lambda t, s: None)
        cache = self.policy.path("cache_root")
        mine = ["DerivedData-mac-integ", "spm-mac-integ-ChatUI", "spm-mac-integ-InAppSettings"]
        theirs = ["DerivedData-mac-integ2", "spm-mac-integ2-ChatUI", "DerivedData", "frameworks", "spm-nanogram-X"]
        for name in mine + theirs:
            (cache / name).mkdir(parents=True)
            (cache / name / "f").write_text("x")
        xcode = self.policy.path("xcode_derived_data")
        ours_xcode = xcode / ("Telegram-Mac-" + "a" * 28)
        other_xcode = xcode / ("Telegram-Mac-" + "b" * 28)
        import plistlib
        for directory, owner in ((ours_xcode, path / "Telegram-Mac.xcworkspace"), (other_xcode, "/elsewhere/x.xcworkspace")):
            directory.mkdir(parents=True)
            (directory / "info.plist").write_bytes(plistlib.dumps({"WorkspacePath": str(owner)}))
        # a sibling worktree that shares the name prefix keeps its scratch
        sibling = self.add("integ2", run_tg=lambda t, s: None)
        self.remove("integ", force=True)
        for name in mine:
            self.assertFalse((cache / name).exists(), name)
        for name in theirs:
            self.assertTrue((cache / name).exists(), name)
        self.assertFalse(ours_xcode.exists())
        self.assertTrue(other_xcode.exists())
        self.assertFalse(path.exists())
        self.assertTrue(sibling.exists())

    def test_prefix_of_another_checkout_is_not_taken(self):
        self.add("mac", run_tg=lambda t, s: None)
        self.add("mac-integ", run_tg=lambda t, s: None)
        cache = self.policy.path("cache_root")
        for name in ("spm-mac-mac-P", "spm-mac-mac-integ-P"):
            (cache / name).mkdir(parents=True)
        self.remove("mac", force=True)
        self.assertFalse((cache / "spm-mac-mac-P").exists())
        self.assertTrue((cache / "spm-mac-mac-integ-P").exists())


if __name__ == "__main__":
    unittest.main()
