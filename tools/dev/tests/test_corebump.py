import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from nanogram import sync  # noqa: E402
from test_parity import OWNER_URL, commit, config_text, init, run  # noqa: E402


class CoreBump(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mac = Path(self.tmp.name) / "mac"
        init(self.mac)
        self.core = self.mac / sync.TELEGRAM_IOS
        init(self.core)
        run(self.core, "remote", "add", "origin", OWNER_URL)
        self.root = commit(self.core, {"submodules/Postbox/A.swift": "a\n"}, "root")
        self.old = commit(self.core, {"submodules/Postbox/A.swift": "a1\n"}, "pinned")
        self.new = commit(self.core, {"submodules/Postbox/A.swift": "a2\n"}, "Postbox: the fix")
        run(self.core, "update-ref", "refs/remotes/origin/main", self.new)
        run(self.core, "checkout", "-q", "--detach", self.old)
        text = config_text().replace("ROOT", self.root).replace("reference main", "reference origin/main")
        (self.mac / "docs").mkdir()
        (self.mac / "docs/mac-core-paths.txt").write_text(text)
        run(self.mac, "add", "docs", sync.TELEGRAM_IOS)
        run(self.mac, "commit", "-q", "-m", "mac")
        self.cfg = sync.parity.load_config(self.mac)

    def plan(self, target=None, **kwargs):
        return sync.plan_core_bump(self.mac, target, fetch=False, cfg=self.cfg, **kwargs)

    def test_plans_the_move_to_main(self):
        plan = self.plan()
        self.assertEqual((plan.old, plan.new), (self.old, self.new))
        self.assertEqual(plan.via, "origin/main")
        self.assertEqual(len(plan.commits), 1)

    def test_apply_stages_and_finish_commits_only_the_pin(self):
        (self.mac / "unrelated.txt").write_text("keep out\n")
        sync.apply_core_bump(self.mac, self.plan())
        message = sync.finish_core_bump(self.mac)
        self.assertEqual(message, f"mac-core: {self.new[:10]} (Postbox: the fix)")
        self.assertEqual(run(self.mac, "rev-parse", f"HEAD:{sync.TELEGRAM_IOS}"), self.new)
        self.assertIn("unrelated.txt", run(self.mac, "status", "--porcelain"))

    def test_revert_restores_the_old_pin(self):
        sync.apply_core_bump(self.mac, self.plan())
        sync.revert_core_bump(self.mac, self.old)
        self.assertEqual(run(self.core, "rev-parse", "HEAD"), self.old)
        self.assertEqual(run(self.mac, "diff", "--cached", "--name-only"), "")

    def test_refuses_uncommitted_core_edits(self):
        (self.core / "submodules/Postbox/A.swift").write_text("dirty\n")
        with self.assertRaisesRegex(sync.SyncError, "committed to iOS main first"):
            self.plan()

    def test_refuses_a_commit_that_is_not_on_main(self):
        run(self.core, "checkout", "-q", "-b", "mac-private", self.old)
        private = commit(self.core, {"submodules/Postbox/A.swift": "mac private\n"}, "mac only")
        run(self.core, "update-ref", "refs/remotes/origin/other", private)
        with self.assertRaisesRegex(sync.SyncError, "neither"):
            self.plan(private)

    def test_accepts_the_lts_branch(self):
        run(self.core, "checkout", "-q", "-b", "lts", self.old)
        lts = commit(self.core, {"submodules/Postbox/A.swift": "cherry\n"}, "cherry-picked fix")
        run(self.core, "update-ref", "refs/remotes/origin/mac/core-lts", lts)
        self.assertEqual(self.plan(lts).via, "origin/mac/core-lts")

    def test_refuses_to_move_backwards_unless_told(self):
        run(self.core, "checkout", "-q", "--detach", self.new)
        run(self.mac, "add", sync.TELEGRAM_IOS)
        run(self.mac, "commit", "-q", "-m", "pin new")
        with self.assertRaisesRegex(sync.SyncError, "only moves forward"):
            self.plan(self.old)
        self.assertEqual(self.plan(self.old, allow_rewind=True).new, self.old)

    def test_refuses_an_unpublished_commit(self):
        run(self.core, "update-ref", "-d", "refs/remotes/origin/main")
        run(self.core, "update-ref", "refs/remotes/origin/main", self.old)
        later = commit(self.core, {"submodules/Postbox/A.swift": "unpushed\n"}, "unpushed")
        with self.assertRaises(sync.SyncError):
            self.plan(later)

    def test_cli_dry_run_changes_nothing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = sync.core_bump_main(["--repo", str(self.mac), "--no-fetch", "--dry-run"])
        self.assertEqual(code, 0)
        self.assertIn("dry run", out.getvalue())
        self.assertEqual(run(self.core, "rev-parse", "HEAD"), self.old)

    def test_cli_error_exit_code(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = sync.core_bump_main(["--repo", str(self.mac), "--no-fetch", "nonexistent-ref"])
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
