"""This checkout's build lock, the file ~/.cache/nanogram-macos/build-<checkout>.lock that buildlock holds.

tg build holds it shared; tg frameworks and tg clean hold it exclusively, so neither changes native libraries or
DerivedData under a running build. A command already running under the lock (buildlock, or a tg command that took
it) does not take it again: buildlock exports NANOGRAM_BUILDLOCK and writes its pid into the file, and every
command run here gets NANOGRAM_BUILDLOCK too.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import os
import subprocess
import sys
import time
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path

from . import config

ENV = "NANOGRAM_BUILDLOCK"
POLL_SECONDS = 5


def lock_file(cache_dir: Path, checkout: Path) -> Path:
    return Path(cache_dir) / f"build-{checkout.name}.lock"


def lock_path(root: Path | None = None) -> Path:
    return lock_file(Path(config.CACHE_DIR), Path(root or config.ROOT))


def is_locked(lock: Path) -> bool:
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        return error.errno in (errno.EWOULDBLOCK, errno.EAGAIN)
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def holder_pid(path: Path) -> int | None:
    try:
        first = Path(path).read_text().split(maxsplit=1)
    except OSError:
        return None
    return int(first[0]) if first and first[0].isdigit() else None


def parent_pid(pid: int) -> int | None:
    result = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True, check=False)
    text = result.stdout.strip()
    return int(text) if result.returncode == 0 and text.isdigit() else None


def is_ancestor(pid: int, parent_of: Callable[[int], int | None] = parent_pid) -> bool:
    current: int | None = os.getpid()
    for _ in range(64):
        if current is None or current <= 1:
            return False
        if current == pid:
            return True
        current = parent_of(current)
    return False


def inherited(path: Path, env: Mapping[str, str]) -> bool:
    if not is_locked(path):
        return False
    if env.get(ENV) == str(path):
        return True
    pid = holder_pid(path)
    return pid is not None and pid > 1 and is_ancestor(pid)


@contextlib.contextmanager
def hold(path: Path, exclusive: bool, env: Mapping[str, str] | None = None,
         sleep: Callable[[float], None] = time.sleep, say: Callable[[str], None] | None = None) -> Iterator[None]:
    path = Path(path)
    say = say or (lambda message: print(message, file=sys.stderr, flush=True))
    if inherited(path, os.environ if env is None else env):
        yield
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
    with open(path, "a") as handle:
        started = time.monotonic()
        waited = False
        while True:
            try:
                fcntl.flock(handle, mode | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not waited:
                    say(f"{path.name}: a build of this checkout is running; waiting")
                    waited = True
                sleep(POLL_SECONDS)
        if waited:
            say(f"{path.name}: acquired after {int(time.monotonic() - started)} s")
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    own, command = (argv[:argv.index("--")], argv[argv.index("--") + 1:]) if "--" in argv else (argv, [])
    parser = argparse.ArgumentParser(prog="python3 -m nanogram.checkoutlock")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--shared", action="store_true")
    mode.add_argument("--exclusive", action="store_true")
    parser.add_argument("--lock", type=Path)
    args = parser.parse_args(own)
    if not command:
        parser.error("missing command after --")
    path = args.lock or lock_path()
    with hold(path, exclusive=args.exclusive):
        return subprocess.call(command, env={**os.environ, ENV: str(path)})


if __name__ == "__main__":
    raise SystemExit(main())
