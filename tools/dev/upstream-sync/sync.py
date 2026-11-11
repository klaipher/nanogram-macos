#!/usr/bin/env python3
"""Upstream sync dry run: what would a new upstream release do to us? (identical file in both repos)

Run by hand, before a merge; nothing runs it on a schedule. It answers three questions without touching either repo:

  1. Which files conflict if the new upstream tag is merged into our branch, grouped by area?
  2. Which pinned dependencies (tgcalls, webrtc, tlottie, mtproto-engine, ...) did upstream bump, and are the new
     upstream commits already in our fork branches?
  3. How much did upstream change, per area?

How, without upstream history in our repo (the iOS repo starts at its own root): everything happens in a scratch bare
repository in a temporary directory that borrows our objects (alternates). There the new upstream tag is fetched
(shallow), and two synthetic commits are made: OLD = the tree of the release we are based on (config `base_commit`; its
tree equals the upstream tag we imported) and NEW = the new upstream tree. `git merge-tree --write-tree
--merge-base=OLD <our branch> NEW` is a real three-way merge computed in memory: no working tree, no refs in our repo.

It never pushes, never fetches anything into our repositories (so upstream tags and branches never appear in them), and
never changes them. Network is used only for the upstream tag and, unless --offline, the pin checks.

  upstream-sync.py --tag release-13.2 [--ours main] [--config FILE] [--offline] [--json] [--fail-on-conflict]
  upstream-sync.py --self-test-config      checks the config file only
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / "upstream-sync.json"
REMOTE_PREFIXES = ("http://", "https://", "ssh://", "git@")
IDENTITY = {"GIT_AUTHOR_NAME": "upstream-sync", "GIT_AUTHOR_EMAIL": "upstream-sync@localhost",
            "GIT_COMMITTER_NAME": "upstream-sync", "GIT_COMMITTER_EMAIL": "upstream-sync@localhost"}


@dataclass
class MergeResult:
    tree: str
    conflicts: list[str] = field(default_factory=list)
    messages: list[str] = field(default_factory=list)

    @property
    def conflict_messages(self) -> list[str]:
        return [m for m in self.messages if m.startswith("CONFLICT")]


@dataclass
class PinChange:
    name: str
    path: str
    old: str | None
    new: str | None
    ours: str | None
    status: str = ""


def load_config(path: Path = DEFAULT_CONFIG) -> dict:
    data = json.loads(path.read_text())
    for key in ("upstream_url", "base_commit", "branch", "areas", "pins"):
        if key not in data:
            raise ValueError(f"{path}: missing '{key}'")
    for pin in data["pins"]:
        for key in ("name", "path"):
            if key not in pin:
                raise ValueError(f"{path}: a pin is missing '{key}'")
    return data


def git(repo: Path | str, *args: str, check: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = dict(os.environ, **(env or {}))
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check, env=full_env)


def parse_merge_tree(text: str) -> MergeResult:
    """Output of `git merge-tree --write-tree --name-only`: tree id, the conflicted paths, a blank line, then the
    informational messages. A clean merge is the tree id alone (possibly followed by messages)."""
    lines = text.split("\n")
    tree = lines[0].strip() if lines else ""
    conflicts, messages, in_messages = [], [], False
    for line in lines[1:]:
        if in_messages:
            if line.strip():
                messages.append(line)
        elif not line.strip():
            in_messages = True
        elif line.startswith(("CONFLICT (", "Auto-merging ", "Removing ")):
            # A merge without a blank separator line: this is already a message.
            in_messages = True
            messages.append(line)
        else:
            conflicts.append(line.strip())
    return MergeResult(tree, sorted(set(conflicts)), messages)


def area_of(path: str, areas: list[dict]) -> str:
    """The first configured area with a matching prefix; otherwise the first two path components."""
    for area in areas:
        if any(path == prefix or path.startswith(prefix) for prefix in area["prefixes"]):
            return area["name"]
    parts = path.split("/")
    return "/".join(parts[:2]) if len(parts) > 2 else (parts[0] if len(parts) == 2 else "(top level)")


def group_by_area(paths: list[str], areas: list[dict]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    for path in sorted(paths):
        grouped.setdefault(area_of(path, areas), []).append(path)
    return dict(sorted(grouped.items(), key=lambda item: (-len(item[1]), item[0])))


def parse_gitlinks(ls_tree: str) -> dict[str, str]:
    """`git ls-tree` lines for submodules: '160000 commit <sha>\\t<path>'."""
    links = {}
    for line in ls_tree.splitlines():
        meta, _, path = line.partition("\t")
        fields = meta.split()
        if len(fields) == 3 and fields[0] == "160000" and path:
            links[path] = fields[2]
    return links


def pin_changes(old: dict[str, str], new: dict[str, str], ours: dict[str, str], pins: list[dict]) -> list[PinChange]:
    """Only pins upstream actually bumped (or added, or removed) between the two releases."""
    changes = []
    for pin in pins:
        path = pin["path"]
        if old.get(path) == new.get(path):
            continue
        changes.append(PinChange(pin["name"], path, old.get(path), new.get(path), ours.get(path)))
    return changes


def short(sha: str | None) -> str:
    return sha[:10] if sha else "-"


def format_report(tag: str, config: dict, ours_ref: str, result: MergeResult, upstream_changed: list[str],
                  pins: list[PinChange]) -> str:
    areas = config["areas"]
    out = [f"Upstream sync dry run: {config.get('base_label', config['base_commit'])} -> {tag}, merged into {ours_ref}", ""]
    changed = group_by_area(upstream_changed, areas)
    out.append(f"Upstream changed {len(upstream_changed)} file(s) between the two releases:")
    for area, files in changed.items():
        out.append(f"  {len(files):5d}  {area}")
    out.append("")
    if not result.conflicts:
        out.append("Merge: clean, no conflicts.")
    else:
        out.append(f"Merge: {len(result.conflicts)} conflicting file(s) in {len(group_by_area(result.conflicts, areas))} area(s):")
        for area, files in group_by_area(result.conflicts, areas).items():
            out.append(f"  {area} ({len(files)})")
            out.extend(f"    {f}" for f in files)
        kinds = [m for m in result.conflict_messages if not m.startswith("CONFLICT (content)")]
        if kinds:
            out.append("  Not plain content conflicts (renames, deletions, modes):")
            out.extend(f"    {m}" for m in kinds)
    out.append("")
    if not pins:
        out.append("Pins: upstream did not bump any watched dependency.")
    else:
        out.append("Pins bumped by upstream:")
        for change in pins:
            out.append(f"  {change.name} ({change.path}): {short(change.old)} -> {short(change.new)}; ours {short(change.ours)}"
                       f"{' - ' + change.status if change.status else ''}")
    return "\n".join(out)


def make_scratch(source_repo: Path, scratch: Path) -> Path:
    """A bare repository that borrows the objects of `source_repo` and never writes to it."""
    common = git(source_repo, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    git(scratch.parent, "init", "--bare", "-q", str(scratch))
    alternates = scratch / "objects" / "info" / "alternates"
    alternates.parent.mkdir(parents=True, exist_ok=True)
    alternates.write_text(str(Path(common) / "objects") + "\n")
    return scratch


def fetch(scratch: Path, url: str, refspec: str, depth: bool = True) -> bool:
    args = ["fetch", "--quiet", "--no-tags"]
    if depth and url.startswith(REMOTE_PREFIXES):
        args.append("--depth=1")
    return git(scratch, *args, url, refspec, check=False).returncode == 0


def synthetic_commits(scratch: Path, base_commit: str, upstream_ref: str) -> tuple[str, str]:
    old_tree = git(scratch, "rev-parse", f"{base_commit}^{{tree}}").stdout.strip()
    new_tree = git(scratch, "rev-parse", f"{upstream_ref}^{{tree}}").stdout.strip()
    old = git(scratch, "commit-tree", old_tree, "-m", "synthetic: the upstream release we are based on", env=IDENTITY).stdout.strip()
    new = git(scratch, "commit-tree", new_tree, "-p", old, "-m", "synthetic: the new upstream release", env=IDENTITY).stdout.strip()
    return old, new


def gitlinks_at(scratch: Path, rev: str, pins: list[dict]) -> dict[str, str]:
    paths = [pin["path"] for pin in pins]
    return parse_gitlinks(git(scratch, "ls-tree", rev, "--", *paths, check=False).stdout)


def check_pin(scratch: Path, change: PinChange, pin: dict) -> str:
    """Is upstream's new pin already in our fork branch? Network; only for pins with a fork branch."""
    if not change.new:
        return "removed upstream"
    if not pin.get("fork_url") or not pin.get("fork_branch") or not pin.get("upstream_url"):
        return "no fork history to compare: bring the change over by hand"
    name = pin["name"]
    if not fetch(scratch, pin["fork_url"], f"+refs/heads/{pin['fork_branch']}:refs/forks/{name}", depth=False):
        return "could not fetch our fork"
    if not fetch(scratch, pin["upstream_url"], change.new, depth=False):
        return "could not fetch upstream's commit"
    included = git(scratch, "merge-base", "--is-ancestor", change.new, f"refs/forks/{name}", check=False).returncode == 0
    if included:
        return f"already in {pin['fork_branch']}"
    return f"NOT in {pin['fork_branch']}: merge upstream {short(change.new)} into the fork first"


def run(repo: Path, tag: str, ours: str | None, config: dict, offline: bool) -> tuple[str, dict]:
    ours_ref = ours or config["branch"]
    ours_sha = git(repo, "rev-parse", "--verify", f"{ours_ref}^{{commit}}").stdout.strip()
    git(repo, "rev-parse", "--verify", f"{config['base_commit']}^{{commit}}")
    with tempfile.TemporaryDirectory(prefix="upstream-sync-") as tmp:
        scratch = make_scratch(repo, Path(tmp) / "scratch.git")
        if not fetch(scratch, config["upstream_url"], f"+refs/tags/{tag}:refs/upstream/new"):
            raise SystemExit(f"cannot fetch tag {tag} from {config['upstream_url']}")
        old, new = synthetic_commits(scratch, config["base_commit"], "refs/upstream/new")
        merged = git(scratch, "merge-tree", "--write-tree", "--name-only", f"--merge-base={old}", ours_sha, new, check=False)
        if merged.returncode not in (0, 1):
            raise SystemExit(f"git merge-tree failed: {merged.stderr.strip()}")
        result = parse_merge_tree(merged.stdout)
        upstream_changed = git(scratch, "diff", "--name-only", old, new).stdout.split("\n")
        upstream_changed = [p for p in upstream_changed if p]
        pins = pin_changes(gitlinks_at(scratch, old, config["pins"]), gitlinks_at(scratch, new, config["pins"]),
                           gitlinks_at(scratch, ours_sha, config["pins"]), config["pins"])
        by_name = {pin["name"]: pin for pin in config["pins"]}
        for change in pins:
            change.status = "not checked (--offline)" if offline else check_pin(scratch, change, by_name[change.name])
    text = format_report(tag, config, ours_ref, result, upstream_changed, pins)
    data = {"tag": tag, "ours": ours_ref, "conflicts": result.conflicts, "clean": not result.conflicts,
            "conflicts_by_area": group_by_area(result.conflicts, config["areas"]),
            "upstream_changed": len(upstream_changed),
            "pins": [vars(change) for change in pins]}
    return text, data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", help="upstream tag to try, e.g. release-13.2")
    parser.add_argument("--ours", help="our branch or commit to merge into (default: the config's branch)")
    parser.add_argument("--repo", type=Path, default=HERE.parents[2])
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--offline", action="store_true", help="skip the pin checks against our fork branches")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--fail-on-conflict", action="store_true")
    parser.add_argument("--self-test-config", action="store_true")
    args = parser.parse_args(argv)
    config = load_config(args.config)
    if args.self_test_config:
        print(f"config ok: {len(config['areas'])} areas, {len(config['pins'])} pins")
        return 0
    if not args.tag:
        parser.error("--tag is required")
    text, data = run(args.repo, args.tag, args.ours, config, args.offline)
    print(json.dumps(data, indent=2) if args.json else text)
    return 1 if args.fail_on_conflict and data["conflicts"] else 0


if __name__ == "__main__":
    sys.exit(main())
