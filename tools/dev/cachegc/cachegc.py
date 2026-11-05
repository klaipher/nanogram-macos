#!/usr/bin/env python3
"""Shared build-cache cleanup for the iOS and the Mac app (identical file in both repos).

Selection is pure (plan_* functions take plain data and return Removal lists); gathering reads the disk and
processes; execution deletes after a second safety check. Configuration: cache-policy.json next to this file.

  cachegc.py run [--dry-run] [--only A,B] [--repo PATH] [--force]
  cachegc.py auto          what tg runs after build/test commands: throttled, time-boxed, quiet, never fails
  cachegc.py report        sizes of every cache root
  cachegc.py verify        policy vs .bazelrc / xcconfig, and the sibling repo's copy of this directory

Output bases whose workspace is gone are removed even while their Bazel server still runs (the server is stopped
first, only when its command line carries --output_base=<that base>). The Bazel disk cache is trimmed to its cap by
least recent use, further when free disk space is below the floor in the policy, and `auto` then skips its throttle.

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
CATEGORIES = ("bazel-output-base", "bazel-disk-cache", "derived-data", "module-cache", "compilation-cache", "spm-build", "spm-scratch", "instruments",
              "build-output", "simulator", "worktree", "tool-tmp")
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
    pids: tuple[int, ...] = ()
    files: tuple[tuple[str, int, float], ...] = ()


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

    @property
    def free_space_floor(self) -> int:
        """Bytes of free disk space below which the cleanup runs at once and trims the Bazel disk cache; 0 = off."""
        return int(float(self.data.get("free_space_floor_gb", 0)) * 1024 ** 3)

    @property
    def disk_cache_min_age(self) -> float:
        """Seconds a disk-cache entry must have been idle before the trim may delete it (a build may be writing it)."""
        return float(self.data.get("bazel_disk_cache_min_age_minutes", 15)) * 60


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


def process_commands() -> list[str]:
    result = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, check=False)
    return result.stdout.splitlines()


def process_table() -> list[tuple[int, str]]:
    result = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=False)
    table = []
    for line in result.stdout.splitlines():
        head, _, command = line.strip().partition(" ")
        try:
            table.append((int(head), command.strip()))
        except ValueError:
            continue
    return table


def pid_command(pid: int) -> str:
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, check=False)
    return result.stdout.strip()


def has_output_base(command: str, base: str) -> bool:
    return re.search(re.escape(f"--output_base={base}") + r"(?=\s|$)", command) is not None


def bazel_server_pids(base: str, table: list[tuple[int, str]], pid_from_file: int | None, own_pid: int) -> list[int]:
    """Processes that are the Bazel server (or a client) of this output base. The pid in server.pid.txt counts only
    when that process really runs with --output_base=<base> (the pid may have been reused); without the file a
    process counts when it mentions the output base and looks like Bazel."""
    pids = []
    for pid, command in table:
        if pid == own_pid or not has_output_base(command, base):
            continue
        looks_like_bazel = "A-server" in command or "bazel" in command.replace(base, "").lower()
        if pid == pid_from_file or looks_like_bazel:
            pids.append(pid)
    return sorted(pids)


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


def plan_output_bases(bases: list[dict], exists, mounted, now: float, recent_s: float) -> list[Removal]:
    """bases: {path, workspace (str|None), server_alive, server_pids, mtime, size}. A base is stale when its
    workspace is gone. A base whose workspace still exists is never touched. When its Bazel server is still running,
    the server is stopped first, but only when the process was verified to run with this output base
    (`server_pids`); a live server that cannot be verified keeps the base."""
    plan = []
    for base in bases:
        workspace = base.get("workspace")
        if not workspace:
            continue
        if exists(workspace) or not mounted(workspace):
            continue
        if now - base["mtime"] < recent_s:
            continue
        if base["server_alive"]:
            pids = tuple(base.get("server_pids") or ())
            if not pids:
                continue
            plan.append(Removal("bazel-output-base", base["path"],
                                f"workspace {workspace} no longer exists; its Bazel server (pid "
                                f"{', '.join(str(p) for p in pids)}) is stopped first", base.get("size", 0),
                                "bazel-orphan", "", pids))
            continue
        plan.append(Removal("bazel-output-base", base["path"], f"workspace {workspace} no longer exists",
                            base.get("size", 0)))
    return plan


def bazel_build_running(commands: list[str]) -> bool:
    """A Bazel client running a command that reads or writes the disk cache (build, test, run, ...)."""
    for command in commands:
        words = command.split()
        if words and re.search(r"(^|/)(bazel|bazel-real|bazelisk)$", words[0]) and any(
                w in ("build", "test", "run", "coverage", "mobile-install", "fetch", "sync") for w in words[1:]):
            return True
    return False


def plan_disk_cache(files: list[tuple[float, int, str]], cap: int, free: int, floor: int, building: bool,
                    now: float, min_age_s: float, chunk_bytes: int = 1024 ** 3, root: str = "") -> list[Removal]:
    """files: (last_used, size, path) of every cache entry. Bazel's own garbage collection only runs while Bazel is
    idle, so the disk cache outgrows its cap. Delete the least recently used entries until the cache is back under
    `cap`, or, when free space is below `floor`, until the shortfall is freed too. Entries used in the last
    `min_age_s` stay (a build may be writing them), and nothing is deleted while a Bazel build runs. The plan is cut
    into chunks of about `chunk_bytes` so the time budget is checked between them."""
    if building or not files:
        return []
    total = sum(size for _, size, _ in files)
    over = max(0, total - cap)
    shortfall = max(0, floor - free) if floor else 0
    target = min(total, max(over, shortfall))
    if target <= 0:
        return []
    if over >= shortfall:
        reason = f"disk cache over its {cap / 1024 ** 3:.0f} GB cap (least recently used first)"
    else:
        reason = (f"free disk space {free / 1024 ** 3:.1f} GB is below the {floor / 1024 ** 3:.0f} GB floor "
                  "(least recently used cache entries first)")
    chosen, freed = [], 0
    for last_used, size, path in sorted(files):
        if freed >= target:
            break
        if now - last_used < min_age_s:
            continue
        chosen.append((path, size, last_used))
        freed += size
    plan, chunk, chunk_size = [], [], 0
    for entry in chosen:
        chunk.append(entry)
        chunk_size += entry[1]
        if chunk_size >= chunk_bytes:
            plan.append(Removal("bazel-disk-cache", root, reason, chunk_size, "disk-cache-trim", "", (), tuple(chunk)))
            chunk, chunk_size = [], 0
    if chunk:
        plan.append(Removal("bazel-disk-cache", root, reason, chunk_size, "disk-cache-trim", "", (), tuple(chunk)))
    return plan


def scan_disk_cache(root: Path, deadline: float, check_every: int = 256) -> list[tuple[float, int, str]] | None:
    """(last_used, size, path) of the regular files under root/ac and root/cas, or None when the deadline passed
    before the scan finished (a partial scan would misjudge the total size)."""
    files: list[tuple[float, int, str]] = []
    stack = [root / "ac", root / "cas"]
    visited = 0
    while stack:
        directory = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(Path(entry.path))
                        elif entry.is_file(follow_symlinks=False) and ".tmp" not in entry.name:
                            info = entry.stat(follow_symlinks=False)
                            files.append((max(info.st_atime, info.st_mtime), info.st_size, entry.path))
                    except OSError:
                        continue
        except OSError:
            continue
        visited += 1
        if visited % check_every == 0 and time.time() > deadline:
            return None
    return files


def free_bytes(path: Path) -> int:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        return shutil.disk_usage(probe).free
    except OSError:
        return 1 << 62


def stop_bazel_servers(path: str, pids: tuple[int, ...], term_wait: float = 10.0, kill_wait: float = 5.0,
                       send=os.kill, command_of=pid_command, alive=pid_alive, sleep=time.sleep) -> bool:
    """Stops the Bazel processes of a deleted workspace: SIGTERM, then SIGKILL for the ones that stay. Each pid is
    verified again right before the signal (--output_base=<path> in its command line); a pid that no longer runs
    with it is left alone. True when none of them is left."""
    targets = [pid for pid in pids if has_output_base(command_of(pid), path)]
    for sig, wait in ((signal.SIGTERM, term_wait), (signal.SIGKILL, kill_wait)):
        for pid in targets:
            if alive(pid):
                try:
                    send(pid, sig)
                except ProcessLookupError:
                    pass
                except OSError:
                    return False
        deadline = time.monotonic() + wait
        while any(alive(pid) for pid in targets) and time.monotonic() < deadline:
            sleep(0.2)
        if not any(alive(pid) for pid in targets):
            return True
    return False


def inside_cache(path: str, root: Path) -> bool:
    """A file path below the cache root (spelled with or without symlinks resolved), without ".." parts."""
    if ".." in path.split("/"):
        return False
    return any(path.startswith(str(prefix).rstrip("/") + "/") for prefix in (root, root.resolve()))


def trim_disk_cache_files(removal: Removal, root: Path) -> bool:
    """Deletes the planned entries that are still where and as old as the scan saw them."""
    removed = 0
    for path, _, last_used in removal.files:
        target = Path(path)
        if not inside_cache(path, root) or target.parent.name == "gc":
            continue
        try:
            info = os.lstat(target)
            if not stat.S_ISREG(info.st_mode) or max(info.st_atime, info.st_mtime) > last_used + 1.0:
                continue
            os.unlink(target)
            removed += 1
        except OSError:
            continue
    return removed > 0 or not removal.files


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
                   cwds: set[str], tools_running: bool) -> list[Removal]:
    """entries: {path, last_used, size}; .build directories inside a repository."""
    plan = []
    for entry in entries:
        age = now - entry["last_used"]
        if tools_running or age < recent_s or age <= unused_days * DAY or cwd_inside(entry["path"], cwds):
            continue
        plan.append(Removal("spm-build", entry["path"], f"SwiftPM .build unused for {int(age // DAY)} days",
                            entry.get("size", 0)))
    return plan


def plan_spm_scratch(entries: list[dict], now: float, unused_days: float, total_cap: int, recent_s: float,
                     locked: set[str], tools_running: bool) -> list[Removal]:
    """entries: {path, last_used, size}; scratch paths under the cache root. Stale first, then LRU down to the cap."""
    plan, removed = [], set()
    usable = [e for e in entries if e["path"] not in locked and now - e["last_used"] >= recent_s]
    if tools_running:
        return []
    for entry in sorted(usable, key=lambda e: e["last_used"]):
        age = now - entry["last_used"]
        if age > unused_days * DAY:
            plan.append(Removal("spm-scratch", entry["path"], f"scratch unused for {int(age // DAY)} days",
                                entry["size"]))
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
    if removal.action == "disk-cache-trim":
        disk_cache = policy.path("bazel_disk_cache")
        if path.name in policy.protected_names or resolved != disk_cache.parent.resolve() / disk_cache.name:
            return "not the Bazel disk cache"
        if any(not inside_cache(f[0], disk_cache) for f in removal.files):
            return "entry outside the Bazel disk cache"
        return None
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


def execute(removal: Removal) -> bool:
    path = Path(removal.path)
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
    if removal.action == "disk-cache-trim":
        return trim_disk_cache_files(removal, path)
    if removal.action == "bazel-orphan" and not stop_bazel_servers(removal.path, removal.pids):
        return False
    make_writable(path)
    shutil.rmtree(path, ignore_errors=True)
    return not path.exists()


def human(size: int) -> str:
    return f"{size / 1024 ** 3:.2f} GB" if size >= 1024 ** 3 else f"{size / 1024 ** 2:.1f} MB"


def git(repo: Path | str, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    return result.stdout


def gather_output_bases(policy: Policy, commands: list[str], now: float,
                        table: list[tuple[int, str]] | None = None) -> list[dict]:
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
        pid_from_file = None
        try:
            pid_from_file = int(pid_file.read_text().strip())
            alive = alive or pid_alive(pid_from_file)
        except (OSError, ValueError):
            pass
        pids: list[int] = []
        if alive:
            if table is None:
                table = process_table()
            pids = bazel_server_pids(str(child), table, pid_from_file, os.getpid())
        bases.append({"path": str(child), "workspace": workspace, "server_alive": alive, "server_pids": pids,
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


def gather_and_plan(policy: Policy, only: set[str], repo: Path | None, now: float, deadline: float,
                    tmpdir: Path) -> tuple[list[Removal], list[str]]:
    plan: list[Removal] = []
    notes: list[str] = []
    commands = process_commands()
    tools_running = build_tool_running(commands)
    recent_s = policy.data["recently_used_minutes"] * 60
    repo_paths = [p for p in policy.repos if p.is_dir()]
    if repo and repo.resolve() not in [p.resolve() for p in repo_paths]:
        repo_paths.append(repo)

    def want(category: str) -> bool:
        return category in only and time.time() < deadline

    if want("bazel-output-base"):
        bases = gather_output_bases(policy, commands, now)
        stale = plan_output_bases(bases, lambda p: Path(p).exists(), mounted, now, recent_s)
        plan += [Removal(r.category, r.path, r.reason, disk_usage(Path(r.path)), r.action) for r in stale]

    if want("bazel-disk-cache"):
        disk_cache = policy.path("bazel_disk_cache")
        if disk_cache.is_dir():
            entries = scan_disk_cache(disk_cache, deadline)
            if entries is None:
                notes.append("bazel disk cache scan did not finish inside the time budget; nothing trimmed")
            else:
                plan += plan_disk_cache(entries, policy.cap_bytes("bazel_disk_cache"), free_bytes(disk_cache),
                                        policy.free_space_floor, bazel_build_running(commands), now,
                                        policy.disk_cache_min_age, root=str(disk_cache))

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
        stale = plan_derived_data(entries, lambda p: Path(p).exists(), mounted, now, policy.days("derived_data_unused"),
                                  recent_s, busy, tools_running or xcode_ide_running(commands))
        plan += [Removal(r.category, r.path, r.reason, disk_usage(Path(r.path))) for r in stale]

    if want("module-cache"):
        module_cache = policy.path("xcode_derived_data") / "ModuleCache.noindex"
        if module_cache.is_dir():
            plan += plan_module_cache(str(module_cache), disk_usage(module_cache), policy.cap_bytes("xcode_module_cache"),
                                      tools_running or xcode_ide_running(commands))

    if want("compilation-cache"):
        cas = policy.path("compilation_cache")
        if cas.is_dir():
            locks = [p for p in policy.path("cache_root").glob("build*.lock") if lock_held(p)]
            plan += plan_module_cache(str(cas), disk_usage(cas), policy.cap_bytes("compilation_cache"),
                                      tools_running or xcode_ide_running(commands) or bool(locks), "compilation-cache")

    if want("spm-build"):
        cwds = process_cwds()
        entries = [{"path": str(p), "last_used": newest_mtime(p), "size": 0}
                   for p in find_build_dirs(extra_repo_dirs(policy, repo_paths))]
        stale = plan_spm_build(entries, now, policy.days("spm_build_unused"), recent_s, cwds, tools_running)
        plan += [Removal(r.category, r.path, r.reason, disk_usage(Path(r.path))) for r in stale]

    cache_root = policy.path("cache_root")
    if want("spm-scratch") and cache_root.is_dir():
        prefix = policy.data["roots"]["spm_scratch_prefix"]
        entries = [{"path": str(p), "last_used": newest_mtime(p), "size": disk_usage(p)}
                   for p in sorted(cache_root.iterdir()) if p.is_dir() and not p.is_symlink() and p.name.startswith(prefix)]
        plan += plan_spm_scratch(entries, now, policy.days("spm_scratch_unused"), policy.cap_bytes("spm_scratch_total"),
                                 recent_s, set(), tools_running)

    if want("instruments"):
        files = []
        for p in tmpdir.glob("instruments*.ktrace"):
            files.append({"path": str(p), "mtime": newest_mtime(p), "size": disk_usage(p)})
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
                        entries.append({"path": str(p), "last_used": newest_mtime(p), "size": disk_usage(p)})
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
    plan = [Removal(r.category, r.path, r.reason, disk_usage(Path(r.path)), r.action) for r in candidates]
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


def run(policy: Policy, only: set[str], dry_run: bool, repo: Path | None = None, now: float | None = None,
        budget: float | None = None, quiet: bool = False, tmpdir: Path | None = None) -> dict:
    now = time.time() if now is None else now
    deadline = time.time() + (budget if budget is not None else 3600)
    tmpdir = Path(tmpdir or os.environ.get("TMPDIR", "/tmp"))
    plan, notes = gather_and_plan(policy, only, repo, now, deadline, tmpdir)
    repo_paths = [p for p in policy.repos if p.is_dir()] + ([repo] if repo else [])
    roots = allowed_roots(policy, extra_repo_dirs(policy, repo_paths), tmpdir)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    freed, removed, refused, lines = 0, 0, 0, [f"{stamp} note: {n}" for n in notes]
    for item in plan:
        if time.time() > deadline:
            lines.append(f"{stamp} budget exhausted; the rest runs next time")
            break
        reason = safe_to_remove(item, policy, roots)
        if reason:
            refused += 1
            lines.append(f"{stamp} REFUSED {item.category} {item.path}: {reason}")
            continue
        ok = True if dry_run else execute(item)
        if ok:
            removed += 1
            freed += item.size
            lines.append(f"{stamp} {'WOULD REMOVE' if dry_run else 'removed'} {item.category} {item.path} "
                         f"({human(item.size)}): {item.reason}")
        else:
            lines.append(f"{stamp} FAILED {item.category} {item.path}")
    verb = "would free" if dry_run else "freed"
    lines.append(f"{stamp} summary: {removed} item(s), {verb} {human(freed)}, {refused} refused"
                 f"{' (dry run)' if dry_run else ''}")
    if not dry_run:
        log_lines(policy.path("log_file"), lines)
    if not quiet:
        print("\n".join(lines))
    return {"removed": removed, "freed": freed, "refused": refused, "lines": lines}


def low_on_space(policy: Policy) -> bool:
    """Free disk space is below the policy floor: the throttle is skipped so the cleanup runs after every command."""
    floor = policy.free_space_floor
    return floor > 0 and free_bytes(policy.path("cache_root")) < floor


def auto(policy: Policy, repo: Path | None) -> int:
    state_path = policy.path("state_file")
    auto_cfg = policy.data["auto"]
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        state = {}
    now = time.time()
    if now - state.get("last_run", 0) < auto_cfg["min_interval_minutes"] * 60 and not low_on_space(policy):
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


def report(policy: Policy) -> int:
    rows = [("Bazel disk cache", policy.path("bazel_disk_cache")), ("Bazel output bases", policy.path("bazel_user_root")),
            ("Xcode DerivedData", policy.path("xcode_derived_data")), ("Cache root", policy.path("cache_root")),
            ("Compilation cache", policy.path("compilation_cache"))]
    for label, path in rows:
        print(f"{label:<22} {human(disk_usage(path)) if path.exists() else '-':>10}  {path}")
    floor = policy.free_space_floor
    free = free_bytes(policy.path("cache_root"))
    print(f"{'Free disk space':<22} {human(free):>10}  floor {human(floor)}{' (BELOW THE FLOOR)' if floor and free < floor else ''}")
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
    xcconfig = repo / "nanogram" / "Nanogram.xcconfig"
    if xcconfig.is_file():
        text = xcconfig.read_text()
        cas = str(policy.path("compilation_cache")).replace(str(policy.home), "$(HOME)")
        if f"COMPILATION_CACHE_CAS_PATH[config=Debug] = {cas}" not in text:
            problems.append(f"Nanogram.xcconfig COMPILATION_CACHE_CAS_PATH is not {cas}")
        limit = str(policy.cap_bytes("compilation_cache"))
        if f"COMPILATION_CACHE_LIMIT_SIZE[config=Debug] = {limit}" not in text:
            problems.append(f"Nanogram.xcconfig COMPILATION_CACHE_LIMIT_SIZE is not {limit}")
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
    for name in ("run", "auto", "report", "verify"):
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
