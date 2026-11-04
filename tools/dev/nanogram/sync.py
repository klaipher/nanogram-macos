"""tg sync-upstream: fast-forward `upstream` to telegram/master and merge it into the current branch.

  python3 -m nanogram.sync [--repo PATH] [--remote telegram] [--branch master]

`upstream` keeps upstream's real history (stage 1 task 1 ruling), so a sync is a fetch, a compare-and-swap
fast-forward of `upstream`, and a `git merge upstream` on a clean working tree. Conflicts are never resolved
here: the merge is left in progress, the conflicted paths are printed and the exit status is 1.

  python3 -m nanogram.sync core-bump [REF|SHA] [--dry-run] [--no-fetch] [--allow-rewind] [--revert SHA] [--finish]
    `tg core-bump`: the only way to move the core pin (submodules/telegram-ios) to a newer iOS `main` commit
    (or `mac/core-lts`); see docs/mac-core-paths.txt and the pin policy in the shared-codebase plan.

Exit status: 0 merged (run the post-merge steps), NOTHING_TO_DO when the branch already has upstream's tip,
1 conflicts, 2 any other error.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from nanogram import config
from nanogram.parity_loader import parity

UPSTREAM_URL = "https://github.com/TelegramMessenger/telegram-macos.git"
LOCAL_BRANCH = "upstream"
TELEGRAM_IOS = "submodules/telegram-ios"
FORK_BRANCH = "nanogram-mac"
NOTHING_TO_DO = 3


class SyncError(Exception):
    pass


@dataclass
class MergeResult:
    clean: bool
    conflicts: list[str]
    up_to_date: bool = False
    telegram_ios: tuple[str, str] | None = None


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        raise SyncError(f"git {' '.join(args)} failed: {(result.stderr or result.stdout).strip()}")
    return result


def rev(repo: Path, name: str) -> str | None:
    result = git(repo, "rev-parse", "--verify", "--quiet", f"{name}^{{commit}}", check=False)
    return result.stdout.strip() or None


def is_ancestor(repo: Path, older: str, newer: str) -> bool:
    return git(repo, "merge-base", "--is-ancestor", older, newer, check=False).returncode == 0


def current_branch(repo: Path) -> str | None:
    result = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    return result.stdout.strip() or None


def update_upstream(repo: Path = config.ROOT, remote: str = "telegram", branch: str = "master",
                    local: str = LOCAL_BRANCH) -> str | None:
    """Fast-forwards `local` to remote/branch; returns the new sha, or None when it is already there."""
    if git(repo, "remote", "get-url", remote, check=False).returncode != 0:
        git(repo, "remote", "add", remote, UPSTREAM_URL)
    tracking = f"refs/remotes/{remote}/{branch}"
    git(repo, "fetch", "--quiet", "--no-tags", remote, f"+refs/heads/{branch}:{tracking}")
    tip = rev(repo, tracking)
    old = rev(repo, f"refs/heads/{local}")
    if tip is None:
        raise SyncError(f"{remote}/{branch} did not resolve after fetching")
    if old is None:
        raise SyncError(f"no `{local}` branch; create it with: git branch {local} {remote}/{branch}")
    if old == tip or is_ancestor(repo, tip, old):
        if old != tip:
            raise SyncError(f"`{local}` ({old[:10]}) is ahead of {remote}/{branch} ({tip[:10]}); "
                            f"`{local}` must only ever hold upstream's commits")
        return None
    if not is_ancestor(repo, old, tip):
        raise SyncError(f"`{local}` ({old[:10]}) has diverged from {remote}/{branch} ({tip[:10]}); "
                        f"upstream rewrote history or `{local}` got a commit of ours — inspect before resetting it")
    if current_branch(repo) == local:
        raise SyncError(f"`{local}` is checked out; switch to your branch first")
    git(repo, "update-ref", "-m", f"tg sync-upstream: {remote}/{branch}", f"refs/heads/{local}", tip, old)
    return tip


def telegram_ios_pin(repo: Path, commit: str) -> str | None:
    result = git(repo, "rev-parse", "--verify", "--quiet", f"{commit}:{TELEGRAM_IOS}", check=False)
    return result.stdout.strip() or None


def rebase_hint(old: str, new: str) -> str:
    return (f"upstream moved {TELEGRAM_IOS} {old[:10]} -> {new[:10]}; rebase our {FORK_BRANCH} branch onto it:\n"
            f"  git -C {TELEGRAM_IOS} fetch origin && git -C {TELEGRAM_IOS} fetch "
            f"https://github.com/TelegramMessenger/Telegram-iOS {new}\n"
            f"  git -C {TELEGRAM_IOS} rebase --onto {new} {old} {FORK_BRANCH}\n"
            f"  git -C {TELEGRAM_IOS} push --force-with-lease origin {FORK_BRANCH}\n"
            f"  git add {TELEGRAM_IOS} && git commit -m 'build(telegram-ios): {FORK_BRANCH} on upstream {new[:10]}'")


def merge_upstream(repo: Path = config.ROOT, local: str = LOCAL_BRANCH) -> MergeResult:
    """`git merge <local>` into the current branch; on conflict the merge stays in progress, nothing is committed."""
    branch = current_branch(repo)
    if branch is None:
        raise SyncError("HEAD is detached; switch to the branch to merge into (main)")
    if branch == local:
        raise SyncError(f"`{local}` is checked out; it only holds upstream's commits — switch to main")
    if rev(repo, "MERGE_HEAD"):
        raise SyncError("a merge is already in progress; finish it (git commit) or git merge --abort")
    target = rev(repo, f"refs/heads/{local}")
    if target is None:
        raise SyncError(f"no `{local}` branch")
    head = rev(repo, "HEAD")
    if is_ancestor(repo, target, head):
        return MergeResult(clean=True, conflicts=[], up_to_date=True)
    dirty = git(repo, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=dirty").stdout
    if dirty.strip():
        raise SyncError(f"uncommitted changes on {branch}; commit them first:\n{dirty.rstrip()}")
    base = git(repo, "merge-base", head, target).stdout.strip()
    old_pin, new_pin = telegram_ios_pin(repo, base), telegram_ios_pin(repo, target)
    pin = (old_pin, new_pin) if old_pin and new_pin and old_pin != new_pin else None
    message = f"Merge upstream telegram-macos {target[:10]} into {branch}"
    merged = git(repo, "merge", "--no-ff", "--no-edit", "-m", message, local, check=False)
    if merged.returncode == 0:
        return MergeResult(clean=True, conflicts=[], telegram_ios=pin)
    conflicts = git(repo, "diff", "--name-only", "--diff-filter=U").stdout.split()
    if not conflicts or not rev(repo, "MERGE_HEAD"):
        raise SyncError(f"git merge {local} failed: {(merged.stderr or merged.stdout).strip()}")
    return MergeResult(clean=False, conflicts=sorted(conflicts), telegram_ios=pin)


@dataclass
class BumpPlan:
    old: str
    new: str
    subject: str
    commits: list[str]
    via: str


def core_dir(repo: Path) -> Path:
    return repo / TELEGRAM_IOS


def default_bump_message(new: str, subject: str) -> str:
    return f"mac-core: {new[:10]} ({subject})"


def plan_core_bump(repo: Path, target: str | None = None, fetch: bool = True, allow_rewind: bool = False,
                   cfg: "parity.Config | None" = None) -> BumpPlan:
    """Validates a core pin move; changes nothing. Raises SyncError with the reason when the move is not allowed."""
    cfg = cfg or parity.load_config(repo)
    core = core_dir(repo)
    if not (core / ".git").exists():
        raise SyncError(f"{TELEGRAM_IOS} is not checked out (tools/dev/tg setup)")
    old = parity.gitlink(repo, "HEAD", TELEGRAM_IOS)
    if old is None:
        raise SyncError(f"no gitlink for {TELEGRAM_IOS} in HEAD")
    dirty = git(core, "status", "--porcelain", "--untracked-files=no", check=False).stdout.strip()
    if dirty:
        raise SyncError(f"{TELEGRAM_IOS} has uncommitted edits; a core fix is committed to iOS main first, never here:\n{dirty}")
    staged = git(repo, "diff", "--cached", "--name-only", check=False).stdout.split()
    if staged:
        raise SyncError("the Mac index has staged changes; commit or unstage them first: " + ", ".join(staged[:5]))
    if fetch:
        remote, _, branch = cfg.reference.partition("/")
        git(core, "fetch", "--quiet", "--no-tags", remote, f"+refs/heads/{branch}:refs/remotes/{cfg.reference}")
        lts_remote, _, lts_branch = cfg.lts_ref.partition("/")
        git(core, "fetch", "--quiet", "--no-tags", lts_remote, f"+refs/heads/{lts_branch}:refs/remotes/{cfg.lts_ref}", check=False)
    reference, lts = rev(core, cfg.reference), rev(core, cfg.lts_ref)
    if reference is None:
        raise SyncError(f"{cfg.reference} is not in {TELEGRAM_IOS}; run without --no-fetch")
    new = rev(core, target or cfg.reference)
    if new is None:
        raise SyncError(f"cannot resolve {target} in {TELEGRAM_IOS}")
    if new == old:
        raise SyncError(f"the pin is already {old[:10]}")
    via = cfg.reference
    if not is_ancestor(core, new, reference):
        if lts and is_ancestor(core, new, lts):
            via = cfg.lts_ref
        else:
            raise SyncError(f"{new[:10]} is on neither {cfg.reference} nor {cfg.lts_ref}; push it to iOS main first")
    if not allow_rewind and not is_ancestor(core, old, new):
        raise SyncError(f"{new[:10]} does not contain the current pin {old[:10]}; the pin only moves forward (--allow-rewind to override)")
    roots = parity.Report()
    parity.check_roots(roots, "core-root", core, [new], cfg.core_roots)
    published, where = parity.reachable_from_owner(core, new, cfg.remote_owner)
    if roots.failed:
        raise SyncError("; ".join(roots.lines()))
    if not published:
        raise SyncError(f"{new[:10]} is not on a {cfg.remote_owner} remote ({where})")
    commits = git(core, "log", "--format=%h %s", f"{old}..{new}", check=False).stdout.splitlines()
    subject = git(core, "log", "-1", "--format=%s", new).stdout.strip()
    return BumpPlan(old, new, subject, commits, via)


def apply_core_bump(repo: Path, plan: BumpPlan) -> None:
    git(core_dir(repo), "checkout", "--quiet", "--detach", plan.new)
    git(repo, "add", TELEGRAM_IOS)


def revert_core_bump(repo: Path, old: str) -> None:
    git(core_dir(repo), "checkout", "--quiet", "--detach", old)
    git(repo, "reset", "--quiet", "--", TELEGRAM_IOS)


def finish_core_bump(repo: Path) -> str:
    """Commits only the pin; the message follows the repo convention `mac-core: <sha10> (<subject>)`."""
    new = rev(core_dir(repo), "HEAD")
    staged = git(repo, "rev-parse", "--verify", "--quiet", f":{TELEGRAM_IOS}", check=False).stdout.strip()
    if new is None or new != staged or new == parity.gitlink(repo, "HEAD", TELEGRAM_IOS):
        raise SyncError("the staged pin does not match the core checkout; run tg core-bump again")
    subject = git(core_dir(repo), "log", "-1", "--format=%s", new).stdout.strip()
    message = default_bump_message(new, subject)
    git(repo, "commit", "--quiet", "-m", message, "--", TELEGRAM_IOS)
    return message


def core_bump_main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="tg core-bump")
    parser.add_argument("target", nargs="?", help="a ref or sha of the core (default: the reference branch, origin/main)")
    parser.add_argument("--repo", type=Path, default=config.ROOT)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-fetch", action="store_true")
    parser.add_argument("--allow-rewind", action="store_true")
    parser.add_argument("--revert", metavar="SHA", help="put the pin back to SHA (used when the gate fails)")
    parser.add_argument("--finish", action="store_true", help="commit the staged pin")
    args = parser.parse_args(argv)
    try:
        if args.revert:
            revert_core_bump(args.repo, args.revert)
            print(f"core-bump: pin put back to {args.revert[:10]}")
            return 0
        if args.finish:
            print("core-bump: committed: " + finish_core_bump(args.repo))
            return 0
        plan = plan_core_bump(args.repo, args.target, fetch=not args.no_fetch, allow_rewind=args.allow_rewind)
        print(f"core-bump: {plan.old[:10]} -> {plan.new[:10]} via {plan.via}, {len(plan.commits)} commit(s):")
        for line in plan.commits[:40]:
            print(f"  {line}")
        if len(plan.commits) > 40:
            print(f"  ... and {len(plan.commits) - 40} more")
        if args.dry_run:
            print("core-bump: dry run, nothing changed")
            return 0
        apply_core_bump(args.repo, plan)
        print(f"core-bump: pin moved to {plan.new[:10]} and staged; proposed message: {default_bump_message(plan.new, plan.subject)}")
        return 0
    except (SyncError, parity.ParityError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "core-bump":
        return core_bump_main(argv[1:])
    parser = argparse.ArgumentParser(prog="tg sync-upstream")
    parser.add_argument("--repo", type=Path, default=config.ROOT)
    parser.add_argument("--remote", default="telegram")
    parser.add_argument("--branch", default="master")
    args = parser.parse_args(argv)
    try:
        new = update_upstream(args.repo, args.remote, args.branch)
        if new:
            print(f"sync: {LOCAL_BRANCH} -> {args.remote}/{args.branch} {new[:10]}")
        else:
            print(f"sync: {LOCAL_BRANCH} already at {args.remote}/{args.branch}")
        result = merge_upstream(args.repo)
    except SyncError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if result.telegram_ios:
        print(rebase_hint(*result.telegram_ios), file=sys.stderr if not result.clean else sys.stdout)
    if result.up_to_date:
        print(f"sync: {current_branch(args.repo)} already contains {LOCAL_BRANCH}; nothing to merge")
        return NOTHING_TO_DO
    if not result.clean:
        print("error: upstream merge stopped on conflicts (nothing committed):", file=sys.stderr)
        for path in result.conflicts:
            print(f"  {path}", file=sys.stderr)
        print("resolve them, `git add` each path and `git commit`, then run `tools/dev/tg sync-upstream --after-merge` "
              "for the post-merge steps; or give up with `git merge --abort`", file=sys.stderr)
        return 1
    print(f"sync: merged {LOCAL_BRANCH} into {current_branch(args.repo)}")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    sys.exit(main())
