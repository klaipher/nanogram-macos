"""The checkout's build lock: tg build holds it shared, tg frameworks and tg clean exclusive, and a command run
under buildlock (which holds it exclusive) never waits for it."""
import fcntl
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import checkoutlock, config, disk  # noqa: E402

TG = Path(__file__).resolve().parents[1] / "tg"
TOOLS = Path(__file__).resolve().parents[1]


def try_lock(path: Path, mode: int) -> bool:
    with open(path, "a") as handle:
        try:
            fcntl.flock(handle, mode | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        fcntl.flock(handle, fcntl.LOCK_UN)
        return True


def hold_in_child(path: Path, mode: str, pid_line: str = "") -> subprocess.Popen:
    code = ("import fcntl,sys,time\n"
            "h=open(sys.argv[1],'w' if sys.argv[3] else 'a'); h.write(sys.argv[3]); h.flush()\n"
            "fcntl.flock(h, fcntl.LOCK_EX if sys.argv[2]=='ex' else fcntl.LOCK_SH)\n"
            "print('locked', flush=True); time.sleep(60)")
    child = subprocess.Popen([sys.executable, "-c", code, str(path), mode, pid_line], stdout=subprocess.PIPE,
                             text=True)
    assert child.stdout.readline().strip() == "locked"
    return child


def stop(child: subprocess.Popen) -> None:
    child.kill()
    child.wait()
    child.stdout.close()


class LockTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)
        patcher = mock.patch.object(config, "CACHE_DIR", self.cache)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.lock = checkoutlock.lock_path(Path("/x/nanogram-macos-test"))


class HoldTests(LockTestCase):
    def test_lock_path_is_buildlocks(self):
        self.assertEqual(self.lock, disk.lock_file(self.cache, Path("/x/nanogram-macos-test")))
        self.assertEqual(self.lock.name, "build-nanogram-macos-test.lock")

    def test_shared_holders_coexist_and_block_exclusive(self):
        with checkoutlock.hold(self.lock, exclusive=False, env={}):
            self.assertTrue(try_lock(self.lock, fcntl.LOCK_SH))
            self.assertFalse(try_lock(self.lock, fcntl.LOCK_EX))
        self.assertTrue(try_lock(self.lock, fcntl.LOCK_EX))

    def test_exclusive_blocks_shared(self):
        with checkoutlock.hold(self.lock, exclusive=True, env={}):
            self.assertFalse(try_lock(self.lock, fcntl.LOCK_SH))

    def test_waits_for_a_running_build(self):
        child = hold_in_child(self.lock, "ex")
        messages = []
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            if len(sleeps) == 2:
                stop(child)

        with checkoutlock.hold(self.lock, exclusive=True, env={}, sleep=sleep, say=messages.append):
            self.assertFalse(try_lock(self.lock, fcntl.LOCK_SH))
        self.assertGreaterEqual(len(sleeps), 2)
        self.assertEqual(len(messages), 2, messages)
        self.assertIn("waiting", messages[0])

    def test_inherited_from_buildlock_env(self):
        child = hold_in_child(self.lock, "ex")
        try:
            self.assertTrue(checkoutlock.inherited(self.lock, {checkoutlock.ENV: str(self.lock)}))
            self.assertFalse(checkoutlock.inherited(self.lock, {checkoutlock.ENV: str(self.lock) + "x"}))
            self.assertFalse(checkoutlock.inherited(self.lock, {}))
        finally:
            stop(child)
        self.assertFalse(checkoutlock.inherited(self.lock, {checkoutlock.ENV: str(self.lock)}))

    def test_inherited_from_buildlock_ancestor(self):
        child = hold_in_child(self.lock, "ex", f"{os.getpid()} /x/nanogram-macos-test tools/dev/tg build\n")
        try:
            self.assertTrue(checkoutlock.inherited(self.lock, {}))
        finally:
            stop(child)

    def test_unrelated_holder_is_not_inherited(self):
        child = hold_in_child(self.lock, "ex", "1 / launchd\n")
        try:
            self.assertFalse(checkoutlock.inherited(self.lock, {}))
        finally:
            stop(child)


class CommandTests(LockTestCase):
    def run_locked(self, mode, command, timeout=20):
        env = {**os.environ, "NANOGRAM_CACHE_DIR": str(self.cache), "PYTHONPATH": str(TOOLS)}
        env.pop(checkoutlock.ENV, None)
        return subprocess.run([sys.executable, "-m", "nanogram.checkoutlock", mode, "--lock", str(self.lock), "--",
                               *command], env=env, capture_output=True, text=True, timeout=timeout)

    def test_run_under_buildlock_does_not_deadlock(self):
        child = hold_in_child(self.lock, "ex", f"{os.getpid()} /x tools/dev/tg build\n")
        try:
            result = self.run_locked("--shared", [sys.executable, "-c",
                                                  f"import os; print(os.environ['{checkoutlock.ENV}'])"])
        finally:
            stop(child)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.lock))

    def test_nested_tg_command_does_not_deadlock(self):
        inner = [sys.executable, "-m", "nanogram.checkoutlock", "--exclusive", "--lock", str(self.lock), "--",
                 sys.executable, "-c", "print('inner ran')"]
        result = self.run_locked("--shared", inner)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inner ran", result.stdout)

    def test_exit_status_passes_through(self):
        self.assertEqual(self.run_locked("--exclusive", [sys.executable, "-c", "raise SystemExit(7)"]).returncode, 7)


class TgWiringTests(unittest.TestCase):
    def test_tg_build_reruns_itself_under_the_shared_lock(self):
        self.assertRegex(TG.read_text(), r"py checkoutlock --shared -- \"\$ROOT/tools/dev/tg\" build ")


if __name__ == "__main__":
    unittest.main()
