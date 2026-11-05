#!/usr/bin/env python3
"""tg worktree add / remove: a parallel checkout with cheap submodules, and its removal with every cache it made.
Identical file in the iOS and the Mac repository (`--flavor ios|mac` selects the parts that differ). Builds nothing.

  worktree.py --repo R --flavor ios|mac add NAME [--branch B] [--from REF]
  worktree.py --repo R --flavor ios|mac remove NAME [--force]

The worktree lives in ~/Projects/wt/<flavor>-<NAME> (NANOGRAM_WORKTREE_ROOT overrides the parent directory), on a new
branch night/<NAME> unless --branch says otherwise.

add:    git worktree add; submodules (iOS: shallow, 8 jobs; Mac: borrowing the objects of the main checkout's
        submodule clones with --reference, which saves 0.5-0.9 GB per worktree); the gitignored configuration (iOS:
        symlinks to the main checkout's dev-configuration.json and user.bazelrc; Mac: tg credentials, tg localfixes and
        tg frameworks, which read ~/.config themselves, so this script never touches secrets); prints the paths the
        worktree will use for DerivedData, SwiftPM scratch and the Bazel output base.
remove: refuses a dirty worktree, unpushed commits (--force overrides these two), a worktree that holds release
        archives in build-output/{testflight,direct}/<build> (move them first; never overridden) and a worktree in use
        (a running process, or the checkout's build lock). Then it stops the Bazel server and deletes the output base
        (iOS) or deletes DerivedData-<suffix>, spm-<name>-* and the Xcode DerivedData of this checkout (Mac), and
        finishes with git worktree remove and prune. A worktree removed by hand leaves the same things behind;
        `cachegc` removes those on the next build.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cachegc"))
import cachegc as gc  # noqa: E402

CONFIG_LINKS = ("build-system/dev-configuration.json", "user.bazelrc")
MAC_TG_STEPS = ("credentials", "localfixes", "frameworks")


class WorktreeError(Exception):
    pass


def git(repo: Path | str, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        raise WorktreeError(f"git {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def worktree_parent() -> Path:
    return Path(os.environ.get("NANOGRAM_WORKTREE_ROOT", Path.home() / "Projects" / "wt"))


def worktree_list(repo: Path) -> list[Path]:
    return [Path(line[9:]).resolve() for line in git(repo, "worktree", "list", "--porcelain").splitlines()
            if line.startswith("worktree ")]


def main_checkout(repo: Path) -> Path:
    return worktree_list(repo)[0]


def target_path(flavor: str, name: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        raise WorktreeError(f"bad worktree name: {name!r}")
    return worktree_parent().resolve() / f"{flavor}-{name}"


def bazel_output_base(workspace: Path) -> str:
    """Where Bazel puts the output base of a workspace: <user root>/<md5 of the workspace path>."""
    return hashlib.md5(str(workspace).encode()).hexdigest()


def submodule_paths(tree: Path) -> list[tuple[str, str]]:
    """(name, path) from .gitmodules, in file order."""
    if not (tree / ".gitmodules").is_file():
        return []
    out = git(tree, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$", check=False)
    pairs = []
    for line in out.splitlines():
        key, _, path = line.partition(" ")
        pairs.append((key[len("submodule."):-len(".path")], path.strip()))
    return pairs


def init_submodules_with_reference(tree: Path, reference_parent: Path | None) -> None:
    """Initialises the submodules of `tree` one level at a time, borrowing objects from the main checkout's clone of
    the same submodule when it exists (`reference_parent` is the main checkout's git directory for this level)."""
    for name, path in submodule_paths(tree):
        reference = reference_parent / "modules" / name if reference_parent else None
        args = ["submodule", "update", "--init"]
        if reference is not None and reference.is_dir():
            args += ["--reference", str(reference)]
        git(tree, *args, "--", path)
        if (tree / path / ".gitmodules").is_file():
            init_submodules_with_reference(tree / path, reference if reference and reference.is_dir() else None)


def mark_references_precious(main: Path) -> None:
    """The worktrees borrow objects from the main checkout's submodule clones; git must never prune them there."""
    common = Path(git(main, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    modules = common / "modules"
    if not modules.is_dir():
        return
    for gitdir in [p.parent for p in modules.rglob("HEAD") if (p.parent / "objects").is_dir()]:
        subprocess.run(["git", "--git-dir", str(gitdir), "config", "core.repositoryformatversion", "1"], check=False)
        subprocess.run(["git", "--git-dir", str(gitdir), "config", "extensions.preciousObjects", "true"], check=False)


def add(repo: Path, flavor: str, name: str, branch: str | None = None, ref: str | None = None,
        run_tg=None, out=print) -> Path:
    path = target_path(flavor, name)
    if path.exists():
        raise WorktreeError(f"{path} already exists")
    main = main_checkout(repo)
    branch = branch or f"night/{name}"
    exists = bool(git(main, "rev-parse", "--verify", "-q", f"refs/heads/{branch}", check=False).strip())
    path.parent.mkdir(parents=True, exist_ok=True)
    if exists:
        if ref:
            raise WorktreeError(f"branch {branch} exists; --from only applies to a new branch")
        git(main, "worktree", "add", str(path), branch)
    else:
        git(main, "worktree", "add", "-b", branch, str(path), ref or "HEAD")
    out(f"worktree {path} on {branch}")
    try:
        if flavor == "ios":
            git(path, "submodule", "update", "--init", "--recursive", "--depth", "1", "--jobs", "8", check=False)
            for link in CONFIG_LINKS:
                source, dest = main / link, path / link
                if source.exists() and not dest.exists():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.symlink_to(source)
                    out(f"linked {link}")
        else:
            common = Path(git(main, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
            mark_references_precious(main)
            init_submodules_with_reference(path, common)
            for step in MAC_TG_STEPS:
                (run_tg or run_tg_default)(path, step)
    except Exception as error:
        out(f"warning: the worktree exists but its setup stopped: {error}")
        raise
    for line in cache_paths(flavor, path):
        out(line)
    return path


def run_tg_default(tree: Path, step: str) -> None:
    result = subprocess.run([str(tree / "tools/dev/tg"), step], cwd=tree, check=False)
    if result.returncode != 0:
        raise WorktreeError(f"tg {step} failed in {tree}")


def cache_paths(flavor: str, path: Path) -> list[str]:
    policy = gc.load_policy()
    cache = policy.path("cache_root")
    if flavor == "mac":
        return [f"DerivedData:   {cache / gc.derived_data_name(path.name)}",
                f"SwiftPM scratch: {cache}/spm-{path.name}-<package>"]
    root = policy.path("bazel_user_root")
    return [f"Bazel output base: {root / bazel_output_base(path)} (created by the first build)"]


def output_bases_of(workspace: Path, user_root: Path) -> list[Path]:
    found = []
    if not user_root.is_dir():
        return found
    for child in user_root.iterdir():
        marker = child / "DO_NOT_BUILD_HERE"
        try:
            if gc.HEX32.match(child.name) and marker.read_text().strip() == str(workspace):
                found.append(child)
        except OSError:
            continue
    return found


def xcode_derived_of(workspace: Path, derived_root: Path) -> list[Path]:
    found = []
    if not derived_root.is_dir():
        return found
    for child in derived_root.iterdir():
        if not (child.is_dir() and gc.XCODE_DERIVED.match(child.name)):
            continue
        try:
            with (child / "info.plist").open("rb") as handle:
                owner = plistlib.load(handle).get("WorkspacePath")
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if owner and (Path(owner) == workspace or Path(owner).is_relative_to(workspace)):
            found.append(child)
    return found


def check_removable(repo: Path, path: Path, force: bool) -> None:
    if path not in worktree_list(repo):
        raise WorktreeError(f"{path} is not a worktree of {repo}")
    if path == main_checkout(repo):
        raise WorktreeError("refusing to remove the main checkout")
    if gc.holds_builds(path):
        raise WorktreeError(f"{path}/build-output holds release archives (build-output/testflight|direct/<build>); "
                            "move them out first")
    if not force:
        if git(path, "status", "--porcelain", check=False).strip():
            raise WorktreeError(f"{path} has uncommitted changes (--force to remove anyway)")
        unpushed = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes", check=False).strip()
        if unpushed not in ("", "0"):
            raise WorktreeError(f"{path} has {unpushed} commit(s) that are on no remote (--force to remove anyway)")
    commands, cwds = gc.process_commands(), gc.process_cwds()
    if gc.in_use(str(path), commands, cwds):
        raise WorktreeError(f"{path} is in use by a running process")


def remove(repo: Path, flavor: str, name: str, force: bool = False, out=print) -> None:
    path = target_path(flavor, name)
    check_removable(repo, path, force)
    policy = gc.load_policy()
    cache = policy.path("cache_root")
    cache.mkdir(parents=True, exist_ok=True)
    lock_path = cache / f"build-{path.name}.lock"
    with open(lock_path, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise WorktreeError(f"a build of {path.name} is running (its build lock is held)") from None
        if flavor == "ios":
            for base in output_bases_of(path, policy.path("bazel_user_root")):
                pid = 0
                try:
                    pid = int((base / "server" / "server.pid.txt").read_text().strip())
                except (OSError, ValueError):
                    pass
                if pid and gc.pid_alive(pid) and not gc.stop_bazel_server(pid, str(base)):
                    raise WorktreeError(f"could not stop the Bazel server (pid {pid}) of {base}")
                gc.make_writable(base)
                shutil.rmtree(base, ignore_errors=True)
                out(f"removed Bazel output base {base}")
        else:
            doomed = [cache / gc.derived_data_name(path.name)]
            others = {p.name for p in worktree_list(repo)} | {path.name}
            if cache.is_dir():
                doomed += [p for p in cache.iterdir() if p.name.startswith("spm-")
                           and gc.scratch_owner(p.name, "spm-", others) == path.name]
            doomed += xcode_derived_of(path, policy.path("xcode_derived_data"))
            for item in doomed:
                if item.is_dir() and not item.is_symlink():
                    gc.make_writable(item)
                    shutil.rmtree(item, ignore_errors=True)
                    out(f"removed {item}")
        git(repo, "worktree", "remove", "--force", str(path))
        git(repo, "worktree", "prune", check=False)
    try:
        lock_path.unlink()
    except OSError:
        pass
    out(f"removed worktree {path} (branch kept: git branch -d to delete it)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg worktree")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--flavor", choices=("ios", "mac"), required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    add_p = commands.add_parser("add")
    add_p.add_argument("name")
    add_p.add_argument("--branch")
    add_p.add_argument("--from", dest="ref")
    rm_p = commands.add_parser("remove")
    rm_p.add_argument("name")
    rm_p.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "add":
            add(args.repo.resolve(), args.flavor, args.name, args.branch, args.ref)
        else:
            remove(args.repo.resolve(), args.flavor, args.name, args.force)
    except WorktreeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
