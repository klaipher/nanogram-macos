import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import sync  # noqa: E402

PIN_A = "a" * 40
PIN_B = "b" * 40


def run(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def commit_file(repo, path, text, message):
    target = Path(repo) / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    run(repo, "add", path)
    run(repo, "commit", "-q", "-m", message)
    return run(repo, "rev-parse", "HEAD")


def set_pin(repo, sha, message):
    run(repo, "update-index", "--add", "--cacheinfo", f"160000,{sha},{sync.TELEGRAM_IOS}")
    run(repo, "commit", "-q", "-m", message)
    return run(repo, "rev-parse", "HEAD")


class TempRepos(unittest.TestCase):
    """`telegram`: upstream's repo (master). `fork`: upstream branch = telegram/master + our main with one commit."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        gitconfig = base / "gitconfig"
        gitconfig.write_text("[user]\n\tname = Test\n\temail = test@example.invalid\n"
                             "[init]\n\tdefaultBranch = master\n")
        patcher = mock.patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(gitconfig), "GIT_CONFIG_NOSYSTEM": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)

        self.telegram = base / "telegram"
        self.telegram.mkdir()
        run(self.telegram, "init", "-q")
        commit_file(self.telegram, "Config.swift", "let source = \"upstream\"\n", "upstream: config")
        set_pin(self.telegram, PIN_A, "upstream: pin telegram-ios")

        self.fork = base / "fork"
        self.fork.mkdir()
        run(self.fork, "init", "-q", "-b", "main")
        run(self.fork, "remote", "add", "telegram", str(self.telegram))
        run(self.fork, "fetch", "-q", "telegram")
        run(self.fork, "branch", "upstream", "telegram/master")
        run(self.fork, "reset", "-q", "--hard", "upstream")
        commit_file(self.fork, "Nanogram.swift", "let name = \"Nanogram\"\n", "ours: Nanogram")

    def upstream_commit(self, path, text, message):
        return commit_file(self.telegram, path, text, message)

    def ref(self, name):
        return run(self.fork, "rev-parse", name)


class UpdateUpstreamTests(TempRepos):
    def test_update_noop_when_upstream_current(self):
        before = self.ref("upstream")
        self.assertIsNone(sync.update_upstream(repo=self.fork))
        self.assertEqual(self.ref("upstream"), before)

    def test_update_fast_forwards_with_real_history(self):
        old = self.ref("upstream")
        new = self.upstream_commit("Other.swift", "x\n", "upstream: other")
        self.assertEqual(sync.update_upstream(repo=self.fork), new)
        self.assertEqual(self.ref("upstream"), new)
        # Real history (Task 1 ruling), not an iOS-style snapshot commit: upstream's own commit, parent = old tip.
        self.assertEqual(self.ref("upstream^"), old)

    def test_update_refuses_diverged_upstream(self):
        run(self.fork, "switch", "-q", "upstream")
        local = commit_file(self.fork, "Local.swift", "x\n", "local commit on upstream")
        run(self.fork, "switch", "-q", "main")
        self.upstream_commit("Other.swift", "x\n", "upstream: other")
        with self.assertRaises(sync.SyncError) as raised:
            sync.update_upstream(repo=self.fork)
        self.assertIn("diverged", str(raised.exception))
        self.assertEqual(self.ref("upstream"), local)

    def test_update_adds_missing_remote(self):
        run(self.fork, "remote", "remove", "telegram")
        with mock.patch.object(sync, "UPSTREAM_URL", str(self.telegram)):
            self.assertIsNone(sync.update_upstream(repo=self.fork))
        self.assertEqual(run(self.fork, "remote", "get-url", "telegram"), str(self.telegram))


class MergeTests(TempRepos):
    def test_clean_merge_keeps_both_sides(self):
        ours = self.ref("main")
        self.upstream_commit("Other.swift", "x\n", "upstream: other")
        sync.update_upstream(repo=self.fork)
        result = sync.merge_upstream(repo=self.fork)
        self.assertEqual(result, sync.MergeResult(clean=True, conflicts=[], up_to_date=False, telegram_ios=None))
        parents = run(self.fork, "rev-list", "--parents", "-n1", "HEAD").split()[1:]
        self.assertEqual(parents, [ours, self.ref("upstream")])
        self.assertTrue((self.fork / "Nanogram.swift").is_file())
        self.assertTrue((self.fork / "Other.swift").is_file())

    def test_up_to_date_merges_nothing(self):
        head = self.ref("HEAD")
        result = sync.merge_upstream(repo=self.fork)
        self.assertTrue(result.clean)
        self.assertTrue(result.up_to_date)
        self.assertEqual(self.ref("HEAD"), head)

    def test_sync_reports_conflicts(self):
        # Review Focus 2: both sides edit Config.swift.
        commit_file(self.fork, "Config.swift", "let source = \"nanogram\"\n", "ours: config")
        head = self.ref("HEAD")
        self.upstream_commit("Config.swift", "let source = \"upstream 2\"\n", "upstream: config 2")
        sync.update_upstream(repo=self.fork)
        result = sync.merge_upstream(repo=self.fork)
        self.assertFalse(result.clean)
        self.assertEqual(result.conflicts, ["Config.swift"])
        # Left in the merge state, nothing committed, no auto-resolution.
        self.assertEqual(self.ref("HEAD"), head)
        self.assertEqual(self.ref("MERGE_HEAD"), self.ref("upstream"))
        self.assertIn("<<<<<<<", (self.fork / "Config.swift").read_text())

    def test_conflicts_exit_1_with_message(self):
        commit_file(self.fork, "Config.swift", "let source = \"nanogram\"\n", "ours: config")
        self.upstream_commit("Config.swift", "let source = \"upstream 2\"\n", "upstream: config 2")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = sync.main(["--repo", str(self.fork)])
        self.assertEqual(status, 1)
        self.assertIn("Config.swift", err.getvalue())
        self.assertIn("git merge --abort", err.getvalue())
        self.assertIn("sync-upstream --after-merge", err.getvalue())

    def test_dirty_tree_refused(self):
        self.upstream_commit("Other.swift", "x\n", "upstream: other")
        sync.update_upstream(repo=self.fork)
        (self.fork / "Nanogram.swift").write_text("edited\n")
        head = self.ref("HEAD")
        with self.assertRaises(sync.SyncError) as raised:
            sync.merge_upstream(repo=self.fork)
        self.assertIn("uncommitted", str(raised.exception))
        self.assertEqual(self.ref("HEAD"), head)

    def test_dirty_tree_fine_when_nothing_to_merge(self):
        (self.fork / "Nanogram.swift").write_text("edited\n")
        self.assertTrue(sync.merge_upstream(repo=self.fork).up_to_date)

    def test_refuses_to_merge_into_upstream_itself(self):
        run(self.fork, "switch", "-q", "upstream")
        with self.assertRaises(sync.SyncError):
            sync.merge_upstream(repo=self.fork)

    def test_telegram_ios_pin_change_reported(self):
        self.upstream_commit("Other.swift", "x\n", "upstream: other")
        set_pin(self.telegram, PIN_B, "upstream: bump telegram-ios")
        sync.update_upstream(repo=self.fork)
        result = sync.merge_upstream(repo=self.fork)
        self.assertTrue(result.clean)
        self.assertEqual(result.telegram_ios, (PIN_A, PIN_B))
        hint = sync.rebase_hint(PIN_A, PIN_B)
        self.assertIn(f"rebase --onto {PIN_B} {PIN_A} nanogram-mac", hint)

    def test_main_exit_codes(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(sync.main(["--repo", str(self.fork)]), sync.NOTHING_TO_DO)
        self.upstream_commit("Other.swift", "x\n", "upstream: other")
        with redirect_stdout(out):
            self.assertEqual(sync.main(["--repo", str(self.fork)]), 0)
        self.assertIn("merged", out.getvalue())


if __name__ == "__main__":
    unittest.main()
