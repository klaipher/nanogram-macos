"""`tg submodules` leaves out the core's nested copies of what this repository pins itself, and only those.

Local git repositories only (no network, no build): a fake core with the six nested submodules, a fake Mac repository
that holds the real tools/dev/tg.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DUPLICATES = (
    "third-party/webrtc/webrtc", "submodules/TgVoipWebrtc/tgcalls", "third-party/twidget/twidget",
    "third-party/widget-sandbox/widget-sandbox", "third-party/quickjs-ng/quickjs",
)
KEPT = "submodules/tlottie/tlottie"  # the build compiles the core's tlottie
ENV = {**os.environ, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always",
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True, check=True).stdout


def make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "main")
    (path / "f").write_text("x\n")
    git(path, "add", "f")
    git(path, "commit", "-q", "-m", "init")
    return path


class SubmodulesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        core = make_repo(base / "core")
        for index, path in enumerate(DUPLICATES + (KEPT,)):
            lib = make_repo(base / f"lib{index}")
            (core / path).parent.mkdir(parents=True, exist_ok=True)
            git(core, "submodule", "add", "-q", str(lib), path)
        git(core, "commit", "-q", "-m", "submodules")
        top = make_repo(base / "top")
        git(top, "submodule", "add", "-q", str(core), "submodules/telegram-ios")
        (top / "tools/dev").mkdir(parents=True)
        shutil.copy(ROOT / "tools/dev/tg", top / "tools/dev/tg")
        git(top, "add", "-A")
        git(top, "commit", "-q", "-m", "tg")
        self.checkout = base / "checkout"
        git(base, "clone", "-q", str(top), str(self.checkout))

    def run_tg(self):
        subprocess.run(["bash", "tools/dev/tg", "submodules"], cwd=self.checkout, env=ENV, capture_output=True, text=True, check=True)

    def populated(self, path):
        return (self.checkout / "submodules/telegram-ios" / path / "f").is_file()

    def test_a_fresh_checkout_gets_everything_but_the_duplicates(self):
        self.run_tg()
        for path in DUPLICATES:
            self.assertFalse(self.populated(path), path)
        self.assertTrue(self.populated(KEPT))

    def test_existing_duplicate_checkouts_are_removed_and_a_second_run_changes_nothing(self):
        git(self.checkout, "submodule", "update", "--init", "--recursive", "-q")
        self.assertTrue(all(self.populated(path) for path in DUPLICATES))
        self.run_tg()
        self.run_tg()
        for path in DUPLICATES:
            self.assertFalse(self.populated(path), path)
        self.assertTrue(self.populated(KEPT))


if __name__ == "__main__":
    unittest.main()
