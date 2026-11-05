#!/usr/bin/env python3
"""Shared build-cache cleanup for the iOS and the Mac app (identical file in both repos).

Selection is pure (plan_* functions take plain data and return Removal lists); gathering reads the disk and
processes; execution deletes after a second safety check. Configuration: cache-policy.json next to this file.

  cachegc.py run [--dry-run] [--only A,B] [--repo PATH] [--force]
  cachegc.py auto          what tg runs after build/test commands: throttled, time-boxed, quiet, never fails
  cachegc.py guard         what tg runs BEFORE build/test commands: not throttled, enforces the hard caps, and
                           refuses to start a build when the disk is below the hard free-space floor
  cachegc.py report        sizes of every cache root
  cachegc.py verify        policy vs .bazelrc / xcconfig, and the sibling repo's copy of this directory

No schedule, no launchd agent, no cron: nothing runs unless a tg command or the person starts it.
"""
from __future__ import annotations

import argparse
import fcntl
import fnmatch
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
POLICY_FILE = HERE / "cache-policy.json"
DAY = 86400
CATEGORIES = ("bazel-output-base", "bazel-disk-cache", "derived-data", "module-cache", "compilation-cache", "spm-build",
              "spm-scratch", "cache-root", "instruments", "build-output", "simulator", "worktree", "tool-tmp")
# What `guard` always enforces: the hard caps and the leftovers of deleted checkouts. Below the soft free-space floor
# it runs every category.
GUARD_CATEGORIES = ("bazel-output-base", "bazel-disk-cache", "spm-scratch", "cache-root")
HEX32 = re.compile(r"^[0-9a-f]{32}$")
XCODE_DERIVED = re.compile(r"^.+-[a-z]{28}$")
BUILD_ID = re.compile(r"^\d{8,}$")


@dataclass(frozen=True)
class Removal:
    category: str
    path: str
    reason: str
    size: int = 0
    action: str = "rmtree"
    repo: str = ""
    pid: int = 0                      # a Bazel server to stop first ("stop-and-rmtree")
    files: tuple[str, ...] = ()       # the files of a "trim" removal (path is then the cache root)


@dataclass
class Policy:
    data: dict
    home: Path = field(default_factory=Path.home)
    user: str = field(default_factory=lambda: os.environ.get("USER", ""))

    def path(self, key: str) -> Path:
        return self.expand(self.data["roots"][key])

    def expand(self, value: str) -> Path:
        value = value.replace("$USER", self.user)
        if value.startswith("~"):
            value = str(self.home) + value[1:]
        return Path(value)

    def days(self, key: str) -> float:
        return float(self.data["max_age_days"][key])

    def cap_bytes(self, key: str) -> int:
        return int(float(self.data["caps_gb"][key]) * 1024 ** 3)

    def setting(self, key: str, default):
        return self.data.get(key, default)

    @property
    def protected_names(self) -> set[str]:
        return set(self.data["protected_names"])

    @property
    def protected_paths(self) -> list[Path]:
        paths = [self.expand(p) for p in self.data["protected_paths"]]
        paths.append(self.path("cache_root") / "launch-home")
        return paths

    @property
    def repos(self) -> list[Path]:
        return [self.expand(p) for p in self.data["repos"]]


def load_policy(path: Path | None = None, home: Path | None = None) -> Policy:
    path = Path(os.environ.get("NANOGRAM_CACHEGC_POLICY", path or POLICY_FILE))
    data = json.loads(path.read_text())
    return Policy(data, home or Path.home())


def newest_mtime(path: Path) -> float:
    try:
        newest = path.lstat().st_mtime
    except OSError:
        return 0.0
    if path.is_dir() and not path.is_symlink():
        try:
            for child in os.scandir(path):
                try:
                    newest = max(newest, child.stat(follow_symlinks=False).st_mtime)
                except OSError:
                    continue
        except OSError:
            pass
    return newest


def disk_usage(path: Path) -> int:
    result = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True, check=False)
    try:
        return int(result.stdout.split()[0]) * 1024
    except (IndexError, ValueError):
        return 0


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lock_held(path: Path) -> bool:
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def lock_in_use(path: Path) -> bool:
    """True when anyone holds the flock on `path`, shared or exclusive (tg build holds its checkout lock shared,
    SwiftPM holds its scratch lock exclusive). Takes and drops the lock at once; an absent file is not in use."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def posix_lock_held(path: Path) -> bool:
    """Java's FileLock (Bazel) is a POSIX record lock, which flock cannot see."""
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError:
        return False
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def process_commands() -> list[str]:
    result = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, check=False)
    return result.stdout.splitlines()


def process_cwds() -> set[str]:
    result = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, text=True, check=False)
    return {line[1:] for line in result.stdout.splitlines() if line.startswith("n")}


def cwd_inside(path: str, cwds: set[str]) -> bool:
    prefix = path.rstrip("/") + "/"
    return any(c == path or c.startswith(prefix) for c in cwds)


def build_tool_running(commands: list[str]) -> bool:
    return any(re.search(r"(^|/)(xcodebuild|swift-build|swift-test|swift-package|swift-frontend|swiftc)( |$)", c)
               for c in commands)


def xcode_ide_running(commands: list[str]) -> bool:
    return any("/Xcode.app/Contents/MacOS/Xcode" in c for c in commands)


def path_mentioned(path: str, commands: list[str]) -> bool:
    return any(path in c for c in commands)


def in_use(path: str, commands: list[str], cwds: set[str], locks: tuple[Path, ...] = ()) -> bool:
    """A directory is in use when its path appears in a running command line, a process has its cwd inside it, or one
    of its locks is held. This is decided per directory: an xcodebuild working somewhere else says nothing about it."""
    return path_mentioned(path, commands) or cwd_inside(path, cwds) or any(lock_in_use(lock) for lock in locks)


class Sizes:
    """Directory sizes remembered between runs (cachegc-sizes.json next to the state file), so a plan does not run `du`
    over tens of gigabytes every time. An entry is reused while the directory's newest top-level mtime is unchanged and
    the measurement is younger than MAX_AGE; deeper changes show up at the latest after MAX_AGE. Also remembers paths
    that could not be removed, so a failure is reported once and not on every run."""
    MAX_AGE = 6 * 3600

    def __init__(self, path: Path | None = None):
        self.path = path
        self.sizes: dict[str, list[float]] = {}
        self.unremovable: set[str] = set()
        self.dirty = False
        if path is not None:
            try:
                data = json.loads(path.read_text())
                self.sizes = {k: v for k, v in data.get("sizes", {}).items() if isinstance(v, list) and len(v) == 3}
                self.unremovable = set(data.get("unremovable", []))
            except (OSError, ValueError, AttributeError):
                pass

    def cached(self, path: Path, mtime: float, now: float) -> int | None:
        entry = self.sizes.get(str(path))
        if entry and entry[0] == mtime and now - entry[2] < self.MAX_AGE:
            return int(entry[1])
        return None

    def get(self, path: Path, mtime: float, now: float, measure: bool = True) -> int:
        known = self.cached(path, mtime, now)
        if known is not None or not measure:
            return known or 0
        size = disk_usage(path)
        self.sizes[str(path)] = [mtime, size, now]
        self.dirty = True
        return size

    def forget(self, path: str) -> None:
        if self.sizes.pop(path, None) is not None:
            self.dirty = True

    def mark_unremovable(self, path: str) -> None:
        self.unremovable.add(path)
        self.dirty = True

    def save(self) -> None:
        if self.path is None or not self.dirty:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps({"sizes": self.sizes, "unremovable": sorted(self.unremovable)}))
        except OSError:
            pass


def plan_output_bases(bases: list[dict], exists, mounted, now: float, recent_s: float,
                      unused_days: float | None = None, keep_workspaces: frozenset[str] = frozenset()) -> list[Removal]:
    """bases: {path, workspace (str|None), server_alive, pid, mtime, size}.

    A base whose workspace is gone is removed at once (the "recent" window does not apply: nothing can build in a
    deleted checkout); if its server is still alive the server is stopped first ("stop-and-rmtree"). A base whose
    workspace exists is removed when no server runs and nothing touched it for `unused_days` (it is rebuilt on the next
    build; the disk cache still holds the work). `keep_workspaces` (the checkout the command runs in) is never removed."""
    plan = []
    for base in bases:
        workspace = base.get("workspace")
        if not workspace or workspace in keep_workspaces:
            continue
        if not exists(workspace):
            if not mounted(workspace):
                continue
            reason = f"workspace {workspace} no longer exists"
            if base["server_alive"]:
                if base.get("pid"):
                    plan.append(Removal("bazel-output-base", base["path"], reason + " (its server is stopped first)",
                                        base.get("size", 0), "stop-and-rmtree", pid=int(base["pid"])))
                continue
            plan.append(Removal("bazel-output-base", base["path"], reason, base.get("size", 0)))
            continue
        if unused_days is None or base["server_alive"]:
            continue
        age = now - base["mtime"]
        if age > unused_days * DAY and age >= recent_s:
            plan.append(Removal("bazel-output-base", base["path"],
                                f"no Bazel command for {int(age // DAY)} days, no server running (rebuilt on demand)",
                                base.get("size", 0)))
    return plan


def plan_bazel_disk_cache(files: list[tuple[str, float, int]], root: str, now: float, cap: int, recent_s: float,
                          gc_busy: bool, target: float = 0.9) -> list[Removal]:
    """files: (path, mtime, size) of every blob under ac/ and cas/. Over the cap, the least recently used go first,
    down to `target` of the cap; blobs touched in the last `recent_s` stay. A removed blob is only a cache miss to
    Bazel. Bazel's own garbage collection runs only after 5 idle minutes, so with builds back to back it never
    keeps the cap; this does."""
    total = sum(size for _, _, size in files)
    if gc_busy or total <= cap:
        return []
    goal = int(cap * target)
    chosen, freed = [], 0
    for path, mtime, size in sorted(files, key=lambda f: f[1]):
        if total - freed <= goal:
            break
        if now - mtime < recent_s:
            break
        chosen.append(path)
        freed += size
    if not chosen:
        return []
    return [Removal("bazel-disk-cache", root, f"{human(total)} is over the {human(cap)} cap; {len(chosen)} least recently "
                    f"used blobs go (down to {human(goal)})", freed, "trim", files=tuple(chosen))]


def plan_derived_data(entries: list[dict], exists, mounted, now: float, unused_days: float, recent_s: float,
                      busy_paths: set[str], tools_running: bool) -> list[Removal]:
    """entries: {path, workspace, last_used, size}."""
    plan = []
    for entry in entries:
        age = now - entry["last_used"]
        if age < recent_s or entry["path"] in busy_paths:
            continue
        workspace = entry.get("workspace")
        if workspace and not exists(workspace) and mounted(workspace):
            plan.append(Removal("derived-data", entry["path"], f"checkout {workspace} no longer exists",
                                entry.get("size", 0)))
        elif age > unused_days * DAY and not tools_running:
            plan.append(Removal("derived-data", entry["path"], f"unused for {int(age // DAY)} days",
                                entry.get("size", 0)))
    return plan


def ours_derived_data(name: str, projects: list[str]) -> bool:
    """Only Nanogram/Telegram DerivedData folders (<project>-<28 letters>); other Xcode projects are never touched."""
    return name.rsplit("-", 1)[0] in projects


def plan_module_cache(path: str, size: int, cap: int, busy: bool, category: str = "module-cache") -> list[Removal]:
    if busy or size <= cap:
        return []
    return [Removal(category, path, f"over the {cap / 1024 ** 3:.0f} GB cap, removed as a whole (rebuilt on demand)",
                    size)]


def plan_spm_build(entries: list[dict], now: float, unused_days: float, recent_s: float,
                   cwds: set[str], busy: set[str] = frozenset()) -> list[Removal]:
    """entries: {path, last_used, size}; .build directories inside a repository. A directory in use (named by a
    running command, a process working inside it) is skipped; nothing else on the machine matters."""
    plan = []
    for entry in entries:
        age = now - entry["last_used"]
        if entry["path"] in busy or age < recent_s or age <= unused_days * DAY or cwd_inside(entry["path"], cwds):
            continue
        plan.append(Removal("spm-build", entry["path"], f"SwiftPM .build unused for {int(age // DAY)} days",
                            entry.get("size", 0)))
    return plan


def plan_spm_scratch(entries: list[dict], now: float, unused_days: float, total_cap: int, recent_s: float,
                     busy: set[str] = frozenset()) -> list[Removal]:
    """entries: {path, last_used, size, orphan}; scratch paths under the cache root. In order: scratch of a checkout
    that no longer exists, scratch unused for `unused_days`, then least recently used down to the cap. A directory in
    use (`busy`: named by a running command, a process inside it, its SwiftPM lock or its checkout's build lock held)
    is never chosen, whatever else is running on the machine."""
    plan, removed = [], set()
    free = [e for e in entries if e["path"] not in busy]
    for entry in free:
        if entry.get("orphan"):
            plan.append(Removal("spm-scratch", entry["path"], "its checkout no longer exists", entry.get("size", 0)))
            removed.add(entry["path"])
    usable = [e for e in free if e["path"] not in removed and now - e["last_used"] >= recent_s]
    for entry in sorted(usable, key=lambda e: e["last_used"]):
        age = now - entry["last_used"]
        if age > unused_days * DAY:
            plan.append(Removal("spm-scratch", entry["path"], f"scratch unused for {int(age // DAY)} days",
                                entry.get("size", 0)))
            removed.add(entry["path"])
    total = sum(e["size"] for e in entries if e["path"] not in removed)
    for entry in sorted(usable, key=lambda e: e["last_used"]):
        if total <= total_cap:
            break
        if entry["path"] in removed:
            continue
        plan.append(Removal("spm-scratch", entry["path"], "over the scratch cap (least recently used)", entry["size"]))
        removed.add(entry["path"])
        total -= entry["size"]
    return plan


def derived_data_name(checkout: str) -> str:
    """The DerivedData directory tg gives a checkout in the cache root (nanogram/config.py: derived_data_dir)."""
    suffix = checkout.removeprefix("nanogram-macos").lstrip("-")
    return f"DerivedData-{suffix}" if suffix else "DerivedData"


def scratch_owner(name: str, prefix: str, checkouts: set[str]) -> str | None:
    """`spm-<checkout>-<package>` belongs to the longest known checkout name that fits."""
    best = None
    for checkout in checkouts:
        if name.startswith(f"{prefix}{checkout}-") and (best is None or len(checkout) > len(best)):
            best = checkout
    return best


def plan_cache_root(entries: list[dict], fixed_bytes: int, now: float, unused_days: float, total_cap: int,
                    recent_s: float, busy: set[str], current: set[str]) -> list[Removal]:
    """entries: {path, kind ("derived-data" | "spm-scratch"), last_used, size, orphan}, the removable top-level entries
    of the cache root; fixed_bytes: everything else in the root (frameworks, CompilationCache, tools), which has its
    own caps. DerivedData-<suffix> whose checkout is gone or that nothing used for `unused_days` goes first; then, while
    the root is over `total_cap` (cache_root_total, which no other code enforced), the least recently used scratch, then
    DerivedData. `current` (this command's own checkout) and anything busy or used in the last `recent_s` stay."""
    plan, removed = [], set()
    candidates = [e for e in entries if e["path"] not in busy and e["path"] not in current]
    for entry in candidates:
        if entry["kind"] != "derived-data":
            continue
        age = now - entry["last_used"]
        if entry.get("orphan"):
            plan.append(Removal("cache-root", entry["path"], "its checkout no longer exists", entry.get("size", 0)))
            removed.add(entry["path"])
        elif age > unused_days * DAY and age >= recent_s:
            plan.append(Removal("cache-root", entry["path"], f"DerivedData unused for {int(age // DAY)} days",
                                entry.get("size", 0)))
            removed.add(entry["path"])
    total = fixed_bytes + sum(e["size"] for e in entries if e["path"] not in removed)
    for kind in ("spm-scratch", "derived-data"):
        for entry in sorted((e for e in candidates if e["kind"] == kind), key=lambda e: e["last_used"]):
            if total <= total_cap:
                return plan
            if entry["path"] in removed or now - entry["last_used"] < recent_s:
                continue
            plan.append(Removal("cache-root", entry["path"],
                                f"cache root over its {human(total_cap)} cap (least recently used)", entry["size"]))
            removed.add(entry["path"])
            total -= entry["size"]
    return plan


def plan_instruments(files: list[dict], now: float, min_age_s: float, open_paths: set[str]) -> list[Removal]:
    """files: {path, mtime, size}."""
    return [Removal("instruments", f["path"], "Instruments trace older than an hour, no open handle", f["size"])
            for f in files if now - f["mtime"] > min_age_s and f["path"] not in open_paths]


def build_key(name: str) -> tuple:
    return (int(name),) if BUILD_ID.match(name) else (-1,)


def plan_build_output(editions: dict[str, list[str]], released: set[tuple[str, str]], keep: int,
                      sizes: dict[str, int], busy: set[str], root: str) -> list[Removal]:
    """editions: {"testflight": [build ids], "direct": [...]}. Released builds are never listed; the newest `keep`
    unreleased builds of each edition stay."""
    plan = []
    for edition, builds in editions.items():
        unreleased = sorted((b for b in builds if (edition, b) not in released), key=build_key, reverse=True)
        for build in unreleased[keep:]:
            path = f"{root}/{edition}/{build}"
            if path in busy:
                continue
            plan.append(Removal("build-output", path, f"unreleased {edition} build, older than the newest {keep}",
                                sizes.get(path, 0)))
    return plan


def plan_build_logs(files: list[dict], now: float, days: float) -> list[Removal]:
    return [Removal("build-output", f["path"], f"log older than {int(days)} days", f["size"], "rm")
            for f in files if now - f["mtime"] > days * DAY]


def plan_worktrees(trees: list[dict], now: float, days: float, cwds: set[str]) -> list[Removal]:
    """trees: {repo, path, merged, clean, locked, prunable, last_used, is_main}."""
    plan = []
    for tree in trees:
        if tree["is_main"] or tree["locked"] or tree.get("holds_builds"):
            continue
        if tree["prunable"]:
            plan.append(Removal("worktree", tree["path"], "directory is gone (git worktree prune)", 0,
                                "worktree-prune", tree["repo"]))
            continue
        if not (tree["merged"] and tree["clean"]):
            continue
        age = now - tree["last_used"]
        if age <= days * DAY or cwd_inside(tree["path"], cwds):
            continue
        plan.append(Removal("worktree", tree["path"], f"branch merged, clean, unused for {int(age // DAY)} days",
                            tree.get("size", 0), "worktree-remove", tree["repo"]))
    return plan


def plan_tool_tmp(entries: list[dict], now: float, days: float, globs: list[str], locked: set[str]) -> list[Removal]:
    plan = []
    for entry in entries:
        name = Path(entry["path"]).name
        if not any(fnmatch.fnmatch(name, g) for g in globs) or entry["path"] in locked:
            continue
        if now - entry["last_used"] > days * DAY:
            plan.append(Removal("tool-tmp", entry["path"], f"scratch older than {days:g} days", entry["size"]))
    return plan


def is_released(edition: str, build: str, directory: Path, tags: list[str], changelog: str,
                legacy_before: str = "") -> bool:
    if (directory / ".released").exists():
        return True
    if legacy_before and BUILD_ID.match(build) and len(build) == len(legacy_before) and build < legacy_before:
        return True
    if any(tag.endswith(f"-{build}") or tag.endswith(f"+{build}") for tag in tags):
        return True
    return build in changelog


def safe_to_remove(removal: Removal, policy: Policy, allowed_roots: list[Path]) -> str | None:
    """Returns a refusal reason, or None when the removal passes the hard rules."""
    path = Path(removal.path)
    resolved = path.parent.resolve() / path.name
    if removal.action in ("simctl", "worktree-prune"):
        return None
    if removal.action == "trim":
        cache = policy.path("bazel_disk_cache")
        return None if resolved == cache.parent.resolve() / cache.name else "not the Bazel disk cache"
    if path.name in policy.protected_names:
        return "protected name"
    for protected in policy.protected_paths:
        protected = protected.resolve() if protected.exists() else protected
        if resolved == protected or protected.is_relative_to(resolved) or resolved.is_relative_to(protected):
            return f"protected path {protected}"
    roots = list(allowed_roots)
    if removal.action == "worktree-remove":
        roots = [p.parent for p in policy.repos] + [Path("/private/tmp"), Path("/tmp")]
    inside = any(resolved != root.resolve() and resolved.is_relative_to(root.resolve()) for root in roots)
    if not inside:
        return "outside the known cache and build roots"
    return None


def allowed_roots(policy: Policy, repo_paths: list[Path], tmpdir: Path) -> list[Path]:
    roots = [policy.path("cache_root"), policy.path("bazel_user_root"), policy.path("xcode_derived_data"), tmpdir]
    return roots + list(repo_paths)


def make_writable(path: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            try:
                if not os.path.islink(full):
                    os.chmod(full, os.stat(full).st_mode | stat.S_IWUSR)
            except OSError:
                pass
    try:
        os.chmod(path, os.stat(path).st_mode | stat.S_IWUSR | stat.S_IXUSR)
    except OSError:
        pass


def bazel_server_command(pid: int) -> str:
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, check=False)
    return result.stdout.strip()


def process_gone(pid: int) -> bool:
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, check=False)
    state = result.stdout.strip()
    return not state or state.startswith("Z")


def stop_bazel_server(pid: int, output_base: str, wait_s: float = 15.0) -> bool:
    """SIGTERM a Bazel server, after checking that the pid really is a server of this output base (pids are reused).
    True when the process is gone."""
    command = bazel_server_command(pid)
    if not command:
        return True
    if "bazel(" not in command or output_base not in command:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if process_gone(pid):
            return True
        time.sleep(0.1)
    return False


def trim_files(root: Path, files: tuple[str, ...]) -> tuple[int, int]:
    """Removes the listed blobs of the Bazel disk cache (only regular files under root/ac and root/cas).
    Returns (files removed, bytes freed)."""
    count, freed = 0, 0
    resolved_root = root.resolve()
    for name in files:
        path = Path(name)
        try:
            relative = path.relative_to(root)
            if relative.parts[0] not in ("ac", "cas") or path.is_symlink() or not path.is_file():
                continue
            size = path.stat().st_size
            path.unlink()
        except (OSError, ValueError, IndexError):
            continue
        if path.parent.resolve().is_relative_to(resolved_root):
            count += 1
            freed += size
    return count, freed


def execute(removal: Removal) -> bool:
    path = Path(removal.path)
    if removal.action == "trim":
        count, _ = trim_files(path, removal.files)
        return count > 0
    if removal.action == "stop-and-rmtree":
        if not stop_bazel_server(removal.pid, removal.path):
            return False
        make_writable(path)
        shutil.rmtree(path, ignore_errors=True)
        return not path.exists()
    if removal.action == "simctl":
        return subprocess.run(["xcrun", "simctl", "delete", "unavailable"], capture_output=True).returncode == 0
    if removal.action == "worktree-prune":
        return subprocess.run(["git", "-C", removal.repo, "worktree", "prune"], capture_output=True).returncode == 0
    if removal.action == "worktree-remove":
        done = subprocess.run(["git", "-C", removal.repo, "worktree", "remove", removal.path],
                              capture_output=True).returncode == 0
        if done:
            subprocess.run(["git", "-C", removal.repo, "worktree", "prune"], capture_output=True)
        return done
    if removal.action == "rm":
        try:
            path.unlink()
            return True
        except OSError:
            return False
    make_writable(path)
    shutil.rmtree(path, ignore_errors=True)
    return not path.exists()


def human(size: int) -> str:
    return f"{size / 1024 ** 3:.2f} GB" if size >= 1024 ** 3 else f"{size / 1024 ** 2:.1f} MB"


def git(repo: Path | str, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    return result.stdout


def gather_output_bases(policy: Policy, commands: list[str], now: float) -> list[dict]:
    root = policy.path("bazel_user_root")
    bases = []
    if not root.is_dir():
        return bases
    for child in sorted(root.iterdir()):
        if not HEX32.match(child.name) or not child.is_dir():
            continue
        marker = child / "DO_NOT_BUILD_HERE"
        try:
            workspace = marker.read_text().strip() or None
        except OSError:
            workspace = None
        alive = path_mentioned(f"--output_base={child}", commands)
        pid_file = child / "server" / "server.pid.txt"
        pid = 0
        try:
            pid = int(pid_file.read_text().strip())
            alive = alive or pid_alive(pid)
        except (OSError, ValueError):
            pass
        bases.append({"path": str(child), "workspace": workspace, "server_alive": alive, "pid": pid,
                      "mtime": newest_mtime(child), "size": 0})
    return bases


def mounted(path: str) -> bool:
    parts = Path(path).parts
    if len(parts) > 2 and parts[1] == "Volumes":
        return Path(*parts[:3]).exists()
    return True


def read_workspace(derived: Path) -> str | None:
    import plistlib
    try:
        with (derived / "info.plist").open("rb") as handle:
            return plistlib.load(handle).get("WorkspacePath")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def find_build_dirs(repo_roots: list[Path]) -> list[Path]:
    found, skip = [], {".git", "node_modules", "build-output", "build-input", "Pods", ".build"}
    seen = set()
    for repo in repo_roots:
        if not repo.is_dir():
            continue
        for dirpath, dirnames, _ in os.walk(repo, followlinks=False):
            depth = len(Path(dirpath).relative_to(repo).parts)
            if ".build" in dirnames and (Path(dirpath) / "Package.swift").exists():
                full = Path(dirpath) / ".build"
                if full not in seen:
                    seen.add(full)
                    found.append(full)
            dirnames[:] = [d for d in dirnames if d not in skip and not d.startswith("bazel-") and depth < 6
                           and not os.path.islink(os.path.join(dirpath, d))]
    return found


def holds_builds(tree: Path) -> bool:
    """A worktree with build-output/{testflight,direct}/<build> keeps archives and dSYMs (ignored by git, so a clean
    status says nothing about them); git worktree remove would delete them, so such a worktree is never removed."""
    for edition in ("testflight", "direct"):
        directory = tree / "build-output" / edition
        try:
            if directory.is_dir() and any(c.is_dir() and BUILD_ID.match(c.name) for c in directory.iterdir()):
                return True
        except OSError:
            return True
    return False


def worktree_entries(repo: Path, bases: list[str]) -> list[dict]:
    text = git(repo, "worktree", "list", "--porcelain")
    trees, current = [], {}
    for line in text.splitlines() + [""]:
        if not line:
            if current:
                trees.append(current)
            current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    base_refs = [b for b in bases if git(repo, "rev-parse", "--verify", "-q", f"refs/heads/{b}").strip()]
    entries = []
    for index, tree in enumerate(trees):
        path = tree.get("worktree", "")
        head = tree.get("HEAD", "")
        merged = bool(head) and any(subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", head, b],
                                                    capture_output=True).returncode == 0 for b in base_refs)
        prunable = "prunable" in tree
        exists = Path(path).is_dir()
        clean = exists and merged and index > 0 and not git(path, "status", "--porcelain").strip()
        entries.append({"repo": str(repo), "path": path, "merged": merged, "clean": clean,
                        "locked": "locked" in tree, "prunable": prunable, "is_main": index == 0,
                        "holds_builds": exists and holds_builds(Path(path)),
                        "last_used": newest_mtime(Path(path)) if exists else 0.0})
    return entries


def known_checkouts(policy: Policy, repo_paths: list[Path]) -> set[str] | None:
    """Names of every checkout that exists: the worktrees of both repositories, plus any directory with a .git beside
    them (~/Projects, ~/Projects/wt). None when the list cannot be trusted (git failed, the current repository is
    missing), which switches the "its checkout is gone" rules off instead of deleting everything."""
    names: set[str] = set()
    for repo in repo_paths:
        if not (repo / ".git").exists():
            continue
        names.update(p.name for p in worktree_entries_paths(repo))
        names.add(repo.name)
        for parent in (repo.parent, repo.parent / "wt"):
            try:
                names.update(c.name for c in parent.iterdir() if (c / ".git").exists())
            except OSError:
                pass
    return names if names else None


def scan_bazel_disk_cache(root: Path, deadline: float) -> list[tuple[str, float, int]] | None:
    """(path, mtime, size) of every blob in ac/ and cas/; None when the scan ran out of time."""
    files = []
    for sub in ("ac", "cas"):
        stack = [root / sub]
        while stack:
            if time.time() > deadline:
                return None
            try:
                with os.scandir(stack.pop()) as it:
                    for entry in it:
                        try:
                            if entry.is_dir(follow_symlinks=False):
                                stack.append(Path(entry.path))
                            elif entry.is_file(follow_symlinks=False):
                                st = entry.stat(follow_symlinks=False)
                                files.append((entry.path, st.st_mtime, st.st_size))
                        except OSError:
                            continue
            except OSError:
                continue
    return files


def gather_and_plan(policy: Policy, only: set[str], repo: Path | None, now: float, deadline: float,
                    tmpdir: Path, sizes: Sizes | None = None) -> tuple[list[Removal], list[str]]:
    sizes = sizes if sizes is not None else Sizes()
    plan: list[Removal] = []
    notes: list[str] = []
    commands = process_commands()
    tools_running = build_tool_running(commands)
    recent_s = policy.data["recently_used_minutes"] * 60
    repo_paths = [p for p in policy.repos if p.is_dir()]
    if repo and repo.resolve() not in [p.resolve() for p in repo_paths]:
        repo_paths.append(repo)
    cache_root = policy.path("cache_root")
    current = repo.name if repo else ""
    cwds_cache: list[set[str]] = []

    def cwds() -> set[str]:
        if not cwds_cache:
            cwds_cache.append(process_cwds())
        return cwds_cache[0]

    def want(category: str) -> bool:
        return category in only and time.time() < deadline

    def measured(path: Path, mtime: float) -> int:
        return sizes.get(path, mtime, now, measure=time.time() < deadline)

    known_cache: list[set[str] | None] = []

    def known() -> set[str] | None:
        if not known_cache:
            names = known_checkouts(policy, repo_paths)
            known_cache.append(names if names and (not current or current in names) else None)
        return known_cache[0]

    def scratch_entries() -> list[dict]:
        prefix = policy.data["roots"]["spm_scratch_prefix"]
        checkouts = known()
        out = []
        if not cache_root.is_dir():
            return out
        for p in sorted(cache_root.iterdir()):
            if not (p.is_dir() and not p.is_symlink() and p.name.startswith(prefix)):
                continue
            owner = scratch_owner(p.name, prefix, checkouts) if checkouts else None
            mtime = newest_mtime(p)
            locks = [p / ".lock"] + ([cache_root / f"build-{owner}.lock"] if owner else [])
            out.append({"path": str(p), "last_used": mtime, "size": measured(p, mtime), "owner": owner,
                        "orphan": checkouts is not None and owner is None and now - mtime >= recent_s,
                        "busy": in_use(str(p), commands, cwds(), tuple(locks))})
        return out

    if want("bazel-output-base"):
        bases = gather_output_bases(policy, commands, now)
        keep = frozenset({str(repo.resolve())} if repo else ())
        plan += plan_output_bases(bases, lambda p: Path(p).exists(), mounted, now, recent_s,
                                  policy.setting("bazel_output_base_unused_days", None), keep)

    if want("bazel-disk-cache"):
        root = policy.path("bazel_disk_cache")
        if root.is_dir():
            gc_busy = any(posix_lock_held(lock) for lock in (root / "gc").glob("*lock*") if lock.is_file())
            files = scan_bazel_disk_cache(root, deadline)
            if files is None:
                notes.append("bazel-disk-cache: scan ran out of time")
            else:
                plan += plan_bazel_disk_cache(files, str(root), now, policy.cap_bytes("bazel_disk_cache"), recent_s,
                                              gc_busy)

    if want("derived-data"):
        derived_root = policy.path("xcode_derived_data")
        entries = []
        if derived_root.is_dir():
            for child in sorted(derived_root.iterdir()):
                if (child.is_dir() and XCODE_DERIVED.match(child.name)
                        and ours_derived_data(child.name, policy.data.get("derived_data_projects", []))):
                    entries.append({"path": str(child), "workspace": read_workspace(child),
                                    "last_used": max(newest_mtime(child), newest_mtime(child / "Build"),
                                                     newest_mtime(child / "Logs")), "size": 0})
        busy = {e["path"] for e in entries if path_mentioned(e["path"], commands)}
        plan += plan_derived_data(entries, lambda p: Path(p).exists(), mounted, now, policy.days("derived_data_unused"),
                                  recent_s, busy, False)

    if want("module-cache"):
        module_cache = policy.path("xcode_derived_data") / "ModuleCache.noindex"
        if module_cache.is_dir():
            plan += plan_module_cache(str(module_cache), measured(module_cache, newest_mtime(module_cache)),
                                      policy.cap_bytes("xcode_module_cache"), tools_running or xcode_ide_running(commands))

    if want("compilation-cache"):
        cas = policy.path("compilation_cache")
        if cas.is_dir():
            locks = [p for p in cache_root.glob("build*.lock") if lock_held(p)]
            plan += plan_module_cache(str(cas), measured(cas, newest_mtime(cas)), policy.cap_bytes("compilation_cache"),
                                      tools_running or xcode_ide_running(commands) or bool(locks), "compilation-cache")

    if want("spm-build"):
        entries = [{"path": str(p), "last_used": newest_mtime(p), "size": 0}
                   for p in find_build_dirs(extra_repo_dirs(policy, repo_paths))]
        busy = {e["path"] for e in entries if path_mentioned(e["path"], commands)}
        plan += plan_spm_build(entries, now, policy.days("spm_build_unused"), recent_s, cwds(), busy)

    if want("spm-scratch") and cache_root.is_dir():
        entries = scratch_entries()
        plan += plan_spm_scratch(entries, now, policy.days("spm_scratch_unused"), policy.cap_bytes("spm_scratch_total"),
                                 recent_s, {e["path"] for e in entries if e["busy"] or e["owner"] == current and current})

    if want("cache-root") and cache_root.is_dir():
        checkouts = known()
        derived_names = {derived_data_name(n): n for n in checkouts or ()}
        prefix = policy.data["roots"]["spm_scratch_prefix"]
        entries, busy, fixed, current_paths = [], set(), 0, set()
        for p in sorted(cache_root.iterdir()):
            if p.is_symlink() or p.name in policy.protected_names:
                continue
            mtime = newest_mtime(p)
            if p.is_dir() and p.name.startswith("DerivedData"):
                workspace = read_workspace(p)
                owner = derived_names.get(p.name)
                alive = (owner is not None) or bool(workspace and Path(workspace).parent.is_dir())
                orphan = checkouts is not None and not alive
                locks = (cache_root / f"build-{owner}.lock",) if owner else ()
                if in_use(str(p), commands, cwds(), locks):
                    busy.add(str(p))
                if owner == current and current:
                    current_paths.add(str(p))
                entries.append({"path": str(p), "kind": "derived-data", "last_used": mtime,
                                "size": measured(p, mtime), "orphan": orphan})
            elif p.is_dir() and p.name.startswith(prefix):
                continue  # counted below from the scratch scan
            else:
                fixed += measured(p, mtime) if p.is_dir() else p.stat().st_size
        for e in scratch_entries():
            if e["busy"]:
                busy.add(e["path"])
            if e["owner"] == current and current:
                current_paths.add(e["path"])
            entries.append({"path": e["path"], "kind": "spm-scratch", "last_used": e["last_used"], "size": e["size"],
                            "orphan": False})
        plan += plan_cache_root(entries, fixed, now, policy.days("derived_data_unused"),
                                policy.cap_bytes("cache_root_total"), recent_s, busy, current_paths)

    if want("instruments"):
        files = []
        for p in tmpdir.glob("instruments*.ktrace"):
            if str(p) in sizes.unremovable:
                continue
            try:
                size = p.stat().st_size
            except OSError:
                continue
            files.append({"path": str(p), "mtime": newest_mtime(p), "size": size})
        open_paths = set()
        for f in files:
            if now - f["mtime"] > policy.data["instruments_min_age_minutes"] * 60:
                result = subprocess.run(["lsof", "-t", "--", f["path"]], capture_output=True, text=True, check=False)
                if result.stdout.strip():
                    open_paths.add(f["path"])
        plan += plan_instruments(files, now, policy.data["instruments_min_age_minutes"] * 60, open_paths)

    if want("build-output"):
        for repo_path in repo_paths:
            plan += gather_build_output(policy, repo_path, now)

    if want("simulator"):
        plan.append(Removal("simulator", "xcrun simctl delete unavailable", "remove unavailable simulators", 0, "simctl"))

    if want("worktree"):
        cwds = process_cwds()
        trees = []
        for repo_path in repo_paths:
            if (repo_path / ".git").exists():
                trees += worktree_entries(repo_path, policy.data["base_branches"])
        plan += plan_worktrees(trees, now, policy.days("worktree_merged"), cwds)

    if want("tool-tmp"):
        entries, days = [], policy.days("tool_tmp")
        for parent in (cache_root / "tmp", tmpdir):
            if parent.is_dir():
                for p in parent.iterdir():
                    if (p.is_dir() and not p.is_symlink()
                            and any(fnmatch.fnmatch(p.name, g) for g in policy.data["tool_tmp_globs"])):
                        entries.append({"path": str(p), "last_used": newest_mtime(p), "size": 0})
        locked = {e["path"] for e in entries if path_mentioned(e["path"], commands)}
        plan += plan_tool_tmp(entries, now, days, policy.data["tool_tmp_globs"], locked)
    return plan, notes


def extra_repo_dirs(policy: Policy, repo_paths: list[Path]) -> list[Path]:
    roots = list(repo_paths)
    for repo in repo_paths:
        if (repo / ".git").exists():
            for tree in worktree_entries_paths(repo):
                if tree not in roots:
                    roots.append(tree)
    return roots


def worktree_entries_paths(repo: Path) -> list[Path]:
    paths = []
    for line in git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            p = Path(line[9:])
            if p.is_dir():
                paths.append(p)
    return paths


def gather_build_output(policy: Policy, repo: Path, now: float) -> list[Removal]:
    root = repo / "build-output"
    if not root.is_dir():
        return []
    tags = git(repo, "tag", "--list").split()
    try:
        changelog = (repo / "CHANGELOG.md").read_text(errors="replace")
    except OSError:
        changelog = ""
    editions, released, sizes = {}, set(), {}
    for edition in ("testflight", "direct"):
        directory = root / edition
        if not directory.is_dir():
            continue
        builds = [c.name for c in directory.iterdir() if c.is_dir() and BUILD_ID.match(c.name)]
        editions[edition] = builds
        for build in builds:
            if is_released(edition, build, directory / build, tags, changelog,
                           str(policy.data.get("released_unknown_before_build", ""))):
                released.add((edition, build))
    root_s = str(root)
    candidates = plan_build_output(editions, released, policy.data["keep_unreleased_builds"], {}, set(), root_s)
    plan = [Removal(r.category, r.path, r.reason, 0, r.action) for r in candidates]
    log_files = []
    for p in root.iterdir():
        if p.is_file() and p.suffix in (".log", ".out", ".time", ".tsv", ".txt", ".patch"):
            log_files.append({"path": str(p), "mtime": p.stat().st_mtime, "size": p.stat().st_size})
    plan += plan_build_logs(log_files, now, policy.days("build_output_logs"))
    return plan


def log_lines(path: Path, lines: list[str], limit: int = 1_000_000) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > limit:
            path.replace(path.with_suffix(".log.1"))
        with path.open("a") as handle:
            handle.write("\n".join(lines) + "\n")
    except OSError:
        pass


def sizes_file(policy: Policy) -> Path:
    return policy.path("state_file").with_name("cachegc-sizes.json")


def run(policy: Policy, only: set[str], dry_run: bool, repo: Path | None = None, now: float | None = None,
        budget: float | None = None, quiet: bool = False, tmpdir: Path | None = None) -> dict:
    now = time.time() if now is None else now
    started = time.time()
    deadline = started + (budget if budget is not None else 3600)
    tmpdir = Path(tmpdir or os.environ.get("TMPDIR", "/tmp"))
    sizes = Sizes(sizes_file(policy))
    free_before = free_gb(policy)
    plan, _ = gather_and_plan(policy, only, repo, now, deadline, tmpdir, sizes)
    repo_paths = [p for p in policy.repos if p.is_dir()] + ([repo] if repo else [])
    roots = allowed_roots(policy, extra_repo_dirs(policy, repo_paths), tmpdir)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    freed, removed, refused, lines, seen = 0, 0, 0, [], set()
    for item in plan:
        if time.time() > deadline:
            lines.append(f"{stamp} budget exhausted; the rest runs next time")
            break
        if item.path in seen and item.action != "trim":
            continue  # two categories chose the same directory
        seen.add(item.path)
        reason = safe_to_remove(item, policy, roots)
        if reason:
            refused += 1
            lines.append(f"{stamp} REFUSED {item.category} {item.path}: {reason}")
            continue
        size = item.size
        if not size and not dry_run and item.action in ("rmtree", "stop-and-rmtree") and deadline - time.time() > 5:
            # Sizes are measured here, once, only for the log of what is about to go (the plan never needs them).
            size = sizes.cached(Path(item.path), newest_mtime(Path(item.path)), now) or 0
        ok = True if dry_run else execute(item)
        if ok:
            removed += 1
            if item.action == "trim" and not dry_run:
                size = item.size
            freed += size
            note = human(size) if size else "size not measured"
            lines.append(f"{stamp} {'WOULD REMOVE' if dry_run else 'removed'} {item.category} {item.path} "
                         f"({note}): {item.reason}")
            sizes.forget(item.path)
        elif item.category == "instruments":
            # Instruments traces that the system will not let go (the same two .ktrace files on every run): said once.
            refused += 1
            sizes.mark_unremovable(item.path)
            lines.append(f"{stamp} REFUSED instruments {item.path}: cannot be removed; not tried again")
        else:
            lines.append(f"{stamp} FAILED {item.category} {item.path}")
    verb = "would free" if dry_run else "freed"
    gained = free_gb(policy) - free_before
    lines.append(f"{stamp} summary: {removed} item(s), {verb} {human(freed)}, {refused} refused"
                 f"{' (dry run)' if dry_run else f', disk free {gained:+.1f} GB'}")
    if not dry_run:
        sizes.save()
        log_lines(policy.path("log_file"), lines)
    if not quiet:
        print("\n".join(lines))
    return {"removed": removed, "freed": freed, "refused": refused, "lines": lines}


def free_gb(policy: Policy) -> float:
    probe = policy.path("cache_root")
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return shutil.disk_usage(probe).free / 1024 ** 3


def guard(policy: Policy, repo: Path | None) -> int:
    """Runs before a build command. Not throttled. Enforces the hard caps (stale output bases and stopped servers of
    deleted checkouts, the Bazel disk cache, SwiftPM scratch, the cache root total). Below the soft free-space floor
    it runs every rule with a longer budget. Below the hard floor it refuses to start the build."""
    floors = policy.setting("free_space_gb", {"soft": 50, "hard": 20})
    guard_cfg = policy.setting("guard", {"time_budget_seconds": 60, "low_disk_budget_seconds": 180})
    before = free_gb(policy)
    low = before < floors["soft"]
    categories = set(CATEGORIES) - {"simulator"} if low else set(GUARD_CATEGORIES)
    budget = guard_cfg["low_disk_budget_seconds"] if low else guard_cfg["time_budget_seconds"]
    result = {"freed": 0, "removed": 0}
    try:
        result = run(policy, categories, dry_run=False, repo=repo, budget=budget, quiet=True)
    except Exception as error:  # a broken cleanup must not stop a build that has room
        print(f"cache guard: cleanup skipped: {error}", file=sys.stderr)
    after = free_gb(policy)
    if result["removed"]:
        print(f"==> cache guard freed {human(result['freed'])}, {after:.0f} GB free (log: {policy.path('log_file')})",
              file=sys.stderr)
    if after < floors["hard"] and not os.environ.get("TG_ALLOW_LOW_DISK"):
        print(f"error: only {after:.1f} GB free (the build needs at least {floors['hard']} GB). What uses the space:",
              file=sys.stderr)
        report(policy, file=sys.stderr)
        print("Free space (tg cache-cleanup, remove old worktrees with tg worktree remove), or set TG_ALLOW_LOW_DISK=1 "
              "to build anyway.", file=sys.stderr)
        return 1
    if low:
        print(f"warning: {after:.0f} GB free, below the {floors['soft']} GB comfort level", file=sys.stderr)
    return 0


def auto(policy: Policy, repo: Path | None) -> int:
    state_path = policy.path("state_file")
    auto_cfg = policy.data["auto"]
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        state = {}
    now = time.time()
    if now - state.get("last_run", 0) < auto_cfg["min_interval_minutes"] * 60:
        return 0
    lock_path = state_path.with_suffix(".lock")
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    try:
        state["last_run"] = now
        run_simulator = now - state.get("last_simulator", 0) > DAY
        categories = set(CATEGORIES) - ({"simulator"} if not run_simulator else set())
        result = run(policy, categories, dry_run=False, repo=repo, budget=auto_cfg["time_budget_seconds"], quiet=True)
        if run_simulator:
            state["last_simulator"] = now
        state["last_freed"] = result["freed"]
        try:
            state_path.write_text(json.dumps(state))
        except OSError:
            pass
        if result["removed"]:
            print(f"==> cache cleanup freed {human(result['freed'])} (log: {policy.path('log_file')})", file=sys.stderr)
    finally:
        os.close(fd)
    return 0


def report(policy: Policy, file=None) -> int:
    file = file or sys.stdout
    rows = [("Bazel disk cache", policy.path("bazel_disk_cache")), ("Bazel output bases", policy.path("bazel_user_root")),
            ("Xcode DerivedData", policy.path("xcode_derived_data")), ("Cache root", policy.path("cache_root")),
            ("Compilation cache", policy.path("compilation_cache"))]
    for label, path in rows:
        print(f"{label:<22} {human(disk_usage(path)) if path.exists() else '-':>10}  {path}", file=file)
    return 0


def verify(policy: Policy, repo: Path) -> int:
    problems = []
    bazelrc = repo / ".bazelrc"
    if bazelrc.is_file():
        text = bazelrc.read_text()
        gc = policy.data["bazel_disk_cache_gc"]
        for flag, value in (("experimental_disk_cache_gc_max_size", gc["max_size"]),
                            ("experimental_disk_cache_gc_max_age", gc["max_age"])):
            match = re.search(rf"^\S*\s*--{flag}=(\S+)", text, re.MULTILINE)
            if not match or match.group(1) != value:
                problems.append(f".bazelrc --{flag} is {match.group(1) if match else 'missing'}, policy says {value}")
        idle = policy.setting("bazel_max_idle_secs", None)
        if idle is not None:
            match = re.search(r"^startup\s+--max_idle_secs=(\d+)", text, re.MULTILINE)
            if not match or int(match.group(1)) != int(idle):
                problems.append(f".bazelrc startup --max_idle_secs is {match.group(1) if match else 'missing'}, "
                                f"policy says {idle}")
    xcconfig = repo / "nanogram" / "Nanogram.xcconfig"
    if xcconfig.is_file():
        text = xcconfig.read_text()
        cas = str(policy.path("compilation_cache")).replace(str(policy.home), "$(HOME)")
        if f"COMPILATION_CACHE_CAS_PATH[config=Debug] = {cas}" not in text:
            problems.append(f"Nanogram.xcconfig COMPILATION_CACHE_CAS_PATH is not {cas}")
        # The LLVM CAS keeps two generations, so it can reach twice its limit: the limit is half the footprint cap.
        limit = str(policy.cap_bytes("compilation_cache") // 2)
        if f"COMPILATION_CACHE_LIMIT_SIZE[config=Debug] = {limit}" not in text:
            problems.append(f"Nanogram.xcconfig COMPILATION_CACHE_LIMIT_SIZE is not {limit} "
                            f"(half of the compilation_cache cap)")
    floors = policy.setting("free_space_gb", None)
    if not floors or not (0 < floors.get("hard", 0) < floors.get("soft", 0)):
        problems.append("free_space_gb needs 0 < hard < soft")
    for sibling in policy.repos:
        other = sibling / "tools" / "dev" / "cachegc"
        if sibling.resolve() == repo.resolve() or not other.is_dir():
            continue
        for name in ("cachegc.py", "cache-policy.json"):
            mine, theirs = HERE / name, other / name
            if not theirs.is_file() or mine.read_bytes() != theirs.read_bytes():
                problems.append(f"{name} differs from {theirs}")
    for problem in problems:
        print(f"cachegc drift: {problem}")
    if not problems:
        print("cachegc ok: policy matches .bazelrc, xcconfig and the sibling repo")
    return 1 if problems else 0


def detect_repo() -> Path:
    return HERE.parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cachegc")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "auto", "guard", "report", "verify"):
        sub = commands.add_parser(name)
        sub.add_argument("--repo", type=Path, default=None)
        if name == "run":
            sub.add_argument("--dry-run", action="store_true")
            sub.add_argument("--only", default="")
    args = parser.parse_args(argv)
    policy = load_policy()
    repo = (args.repo or detect_repo()).resolve()
    if args.command == "auto":
        try:
            return auto(policy, repo)
        except Exception as error:
            print(f"cache cleanup skipped: {error}", file=sys.stderr)
            return 0
    if args.command == "guard":
        try:
            return guard(policy, repo)
        except Exception as error:
            print(f"cache guard skipped: {error}", file=sys.stderr)
            return 0
    if args.command == "report":
        return report(policy)
    if args.command == "verify":
        return verify(policy, repo)
    only = set(filter(None, args.only.split(","))) or set(CATEGORIES)
    unknown = only - set(CATEGORIES)
    if unknown:
        print(f"unknown categories: {', '.join(sorted(unknown))}; known: {', '.join(CATEGORIES)}", file=sys.stderr)
        return 2
    run(policy, only, args.dry_run, repo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
