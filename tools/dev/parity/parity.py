#!/usr/bin/env python3
"""Parity gate between the iOS and macOS Nanogram repositories.

This file is identical in both repos (tools/dev/parity/parity.py); it reads docs/mac-core-paths.txt, which is also
identical in both. Standard library only.

  parity.py check   [--root DIR] [--release] [--pin SHA] [--ios-repo DIR] [--ios-ref REF] [--today YYYY-MM-DD]
  parity.py fast    [--root DIR] [--mac-repo DIR]            iOS side: history root, pins pushed, never a Mac build
  parity.py roots   [--root DIR] [--config FILE] REV...     every root commit of REV must be an allowed root
  parity.py push    [--root DIR] REMOTE [URL]               pre-push hook body (reads refs on stdin)
  parity.py suggest-allow [--root DIR]                      print webrtc allow lines for the current differences

The side is detected from the checkout: a Mac checkout has the core submodule at the path of the `core` directive.
Exit status 1 when any check reports an error.
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_RELATIVE = "docs/mac-core-paths.txt"
ZERO_SHA = "0" * 40
SOURCE_SUFFIXES = (".cc", ".h", ".mm", ".m", ".c", ".cpp", ".hpp", ".inc", ".s", ".asm", ".swift", ".rs")


class ParityError(Exception):
    pass


@dataclass
class Allow:
    scope: str
    prefix: str
    reason: str
    until: datetime.date | None = None


@dataclass
class Pin:
    name: str
    ios: str
    mac: str
    external: bool = False
    warn_until: datetime.date | None = None


@dataclass
class Config:
    core_path: str = "submodules/telegram-ios"
    core_roots: list[str] = field(default_factory=list)
    repo_roots: dict[str, list[str]] = field(default_factory=dict)
    mode: str = "shared"
    reference: str = "origin/main"
    lts_ref: str = "origin/mac/core-lts"
    lag_commits: int = 20
    lag_days: int = 7
    block_from: datetime.date | None = None
    pins: list[Pin] = field(default_factory=list)
    shares: list[str] = field(default_factory=list)
    allows: list[Allow] = field(default_factory=list)
    webrtc_mac_root: str = "src"
    webrtc_ios_root: str = ""
    remote_owner: str = "klaipher"


def parse_config(text: str) -> Config:
    config = Config()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip() if not raw.lstrip().startswith("allow") else raw.strip()
        if not line or line.startswith("#"):
            continue
        reason = ""
        if line.startswith("allow") and "|" in line:
            line, _, reason = line.partition("|")
            line = line.strip()
            reason = reason.strip()
        words = line.split()
        key, rest = words[0], words[1:]

        def bad(message: str) -> ParityError:
            return ParityError(f"{CONFIG_RELATIVE}:{number}: {message}")

        if key == "core":
            config.core_path = rest[0]
        elif key == "core-root":
            config.core_roots.append(rest[0])
        elif key == "repo-root":
            config.repo_roots.setdefault(rest[0], []).append(rest[1])
        elif key == "mode":
            if rest[0] not in ("legacy", "shared"):
                raise bad("mode is legacy or shared")
            config.mode = rest[0]
        elif key == "reference":
            config.reference = rest[0]
        elif key == "lts-ref":
            config.lts_ref = rest[0]
        elif key == "remote-owner":
            config.remote_owner = rest[0]
        elif key == "lag":
            for item in rest:
                name, _, value = item.partition("=")
                if name == "commits":
                    config.lag_commits = int(value)
                elif name == "days":
                    config.lag_days = int(value)
                elif name == "block-from":
                    config.block_from = datetime.date.fromisoformat(value)
                else:
                    raise bad(f"unknown lag option {name}")
        elif key == "pin":
            options = dict(item.split("=", 1) for item in rest[1:] if "=" in item)
            until = options.get("warn-until")
            config.pins.append(Pin(rest[0], options.get("ios", ""), options.get("mac", ""), "external" in rest[1:],
                                   datetime.date.fromisoformat(until) if until else None))
        elif key == "share":
            config.shares.append(rest[0].rstrip("/"))
        elif key == "webrtc-root":
            options = dict(item.split("=", 1) for item in rest)
            config.webrtc_mac_root = options.get("mac", config.webrtc_mac_root).strip("/")
            config.webrtc_ios_root = options.get("ios", config.webrtc_ios_root).strip("/")
        elif key == "allow":
            if len(rest) < 2 or rest[0] not in ("core", "webrtc"):
                raise bad("allow core|webrtc <path-prefix> [until=YYYY-MM-DD] | reason")
            if not reason:
                raise bad("an allow entry needs a reason after |")
            until = None
            for item in rest[2:]:
                if item.startswith("until="):
                    until = datetime.date.fromisoformat(item[6:])
            config.allows.append(Allow(rest[0], rest[1].strip("/"), reason, until))
        else:
            raise bad(f"unknown directive {key}")
    return config


def load_config(root: Path, path: Path | None = None) -> Config:
    target = path or root / CONFIG_RELATIVE
    if not target.is_file():
        raise ParityError(f"{target} is missing")
    return parse_config(target.read_text())


def covers(prefix: str, path: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


def is_allowed(config: Config, scope: str, path: str, today: datetime.date) -> Allow | None:
    for allow in config.allows:
        if allow.scope == scope and covers(allow.prefix, path) and (allow.until is None or today <= allow.until):
            return allow
    return None


def git(repo: Path, *args: str, check: bool = True, stdin: str | None = None) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, input=stdin, check=False)
    if check and result.returncode != 0:
        raise ParityError(f"git {' '.join(args)} failed in {repo}: {(result.stderr or result.stdout).strip()}")
    return result.stdout if result.returncode == 0 else ""


def git_ok(repo: Path, *args: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=False).returncode == 0


def rev(repo: Path, name: str) -> str | None:
    out = git(repo, "rev-parse", "--verify", "--quiet", f"{name}^{{commit}}", check=False).strip()
    return out or None


def has_object(repo: Path, sha: str) -> bool:
    return git_ok(repo, "cat-file", "-e", f"{sha}^{{commit}}")


def is_ancestor(repo: Path, older: str, newer: str) -> bool:
    return git_ok(repo, "merge-base", "--is-ancestor", older, newer)


def gitlink(repo: Path, ref: str, path: str) -> str | None:
    out = git(repo, "ls-tree", ref, "--", path, check=False).strip()
    if not out:
        return None
    mode, kind, sha = out.split(None, 3)[:3]
    return sha if mode == "160000" else None


def file_exists_at(repo: Path, ref: str, path: str) -> str | None:
    return git(repo, "show", f"{ref}:{path}", check=False) or None


class Report:
    def __init__(self) -> None:
        self.items: list[tuple[str, str, str]] = []

    def add(self, level: str, name: str, message: str) -> None:
        self.items.append((level, name, message))

    def error(self, name: str, message: str) -> None:
        self.add("error", name, message)

    def warn(self, name: str, message: str) -> None:
        self.add("warning", name, message)

    def ok(self, name: str, message: str) -> None:
        self.add("ok", name, message)

    @property
    def failed(self) -> bool:
        return any(level == "error" for level, _, _ in self.items)

    def lines(self) -> list[str]:
        return [f"{level}: [{name}] {message}" for level, name, message in self.items]


def root_commits(repo: Path, revs: list[str]) -> set[str]:
    out = git(repo, "rev-list", "--max-parents=0", *revs)
    return set(out.split())


def check_roots(report: Report, name: str, repo: Path, revs: list[str], allowed: list[str]) -> None:
    if not allowed:
        report.warn(name, "no allowed history root is configured; root check skipped")
        return
    try:
        roots = root_commits(repo, revs)
    except ParityError as error:
        report.error(name, str(error))
        return
    foreign = sorted(r for r in roots if not any(r.startswith(a) or a.startswith(r) for a in allowed))
    if foreign:
        report.error(name, "history reaches a root that is not ours (Telegram's history?): "
                     + ", ".join(r[:10] for r in foreign) + "; allowed: " + ", ".join(a[:10] for a in allowed))
    else:
        report.ok(name, f"every pushed history is rooted at {', '.join(a[:10] for a in allowed)}")


def reachable_from_owner(repo: Path, sha: str, owner: str) -> tuple[bool, str]:
    if not has_object(repo, sha):
        return False, "the commit is not in this checkout"
    refs = git(repo, "for-each-ref", "--contains", sha, "--format=%(refname)", "refs/remotes").split()
    owned = []
    for ref in refs:
        remote = ref.split("/")[2] if ref.startswith("refs/remotes/") else ""
        url = git(repo, "remote", "get-url", remote, check=False).strip()
        if f"/{owner}/" in url or url.endswith(f":{owner}") or f":{owner}/" in url:
            owned.append(ref)
    if owned:
        return True, owned[0]
    return False, "no remote-tracking branch of " + owner + " contains it"


def shared_paths_touched(repo: Path, sha: str, shares: list[str]) -> list[str]:
    out = git(repo, "diff-tree", "-r", "-m", "--first-parent", "--no-commit-id", "--name-only", sha, check=False)
    return [p for p in out.split("\n") if p and any(covers(s, p) for s in shares)]


def cherry_picked_from_reference(repo: Path, sha: str, reference: str) -> bool:
    body = git(repo, "show", "-s", "--format=%B", sha, check=False)
    for source in re.findall(r"cherry picked from commit ([0-9a-f]{7,40})", body):
        if has_object(repo, source) and is_ancestor(repo, source, reference):
            return True
    return False


def core_ahead_and_behind(report: Report, repo: Path, pin: str, reference: str, config: Config,
                          today: datetime.date, lts: str | None) -> None:
    legacy = config.mode == "legacy"
    soft = report.warn if legacy else report.error
    suffix = " (not enforced until the Mac is repointed: mode legacy)" if legacy else ""
    base = reference
    ancestor_of = is_ancestor(repo, pin, reference)
    if not ancestor_of and lts and is_ancestor(repo, pin, lts):
        merge_base = git(repo, "merge-base", lts, reference, check=False).strip()
        if merge_base:
            ancestor_of = True
    if not ancestor_of:
        soft("core-ancestry", f"the pin {pin[:10]} is not an ancestor of {config.reference}"
             + (f" or {config.lts_ref}" if lts else "") + suffix)
    else:
        report.ok("core-ancestry", f"the pin {pin[:10]} is on {config.reference}" + (" (via LTS)" if lts and not is_ancestor(repo, pin, reference) else ""))

    plus = [line.split()[1] for line in git(repo, "cherry", pin, reference, check=False).splitlines() if line.startswith("+")]
    behind: list[tuple[str, int]] = []
    if plus:
        out = git(repo, "log", "--no-walk=unsorted", "--format=@@%H %ct", "--name-only", *plus, check=False)
        current = None
        stamp = 0
        touched = False
        for line in out.splitlines():
            if line.startswith("@@"):
                if current and touched:
                    behind.append((current, stamp))
                current, stamp = line[2:].split()[0], int(line.split()[1])
                touched = False
            elif line and any(covers(s, line) for s in config.shares):
                touched = True
        if current and touched:
            behind.append((current, stamp))
    count = len(behind)
    oldest_days = 0
    if behind:
        oldest = min(stamp for _, stamp in behind)
        oldest_days = (today - datetime.date.fromtimestamp(oldest)).days
    exceeded = count > config.lag_commits or oldest_days > config.lag_days
    blocking = not legacy and (config.block_from is None or today >= config.block_from)
    summary = (f"{count} commit(s) on {config.reference} touching shared paths are not on the pin; "
               f"oldest {oldest_days} day(s); limit {config.lag_commits} commits / {config.lag_days} days")
    if exceeded:
        (report.error if blocking else report.warn)(
            "core-lag", summary + ("; run tools/dev/tg core-bump" if blocking else
                                   "; warning only" + (f" until {config.block_from}" if config.block_from else suffix)))
    else:
        report.ok("core-lag", summary)

    diff_names = [p for p in git(repo, "diff", "--name-only", pin, reference, check=False).split("\n")
                  if p and any(covers(s, p) for s in config.shares)]
    pin_only = git(repo, "rev-list", "--no-merges", f"{reference}..{pin}", check=False).split()
    equivalent = {line.split()[1] for line in git(repo, "cherry", reference, pin, check=False).splitlines() if line.startswith("-")}
    mac_touched: set[str] = set()
    for sha in pin_only:
        if sha in equivalent or cherry_picked_from_reference(repo, sha, reference):
            continue
        mac_touched.update(shared_paths_touched(repo, sha, config.shares))
    unexplained = sorted(p for p in diff_names if p in mac_touched and not is_allowed(config, "core", p, today))
    if unexplained:
        shown = ", ".join(unexplained[:8]) + (f" and {len(unexplained) - 8} more" if len(unexplained) > 8 else "")
        soft("core-files", f"{len(unexplained)} shared file(s) differ from {config.reference} through commits that are not "
             f"cherry-picks of it and have no allow entry in {CONFIG_RELATIVE}: {shown}{suffix}")
    else:
        report.ok("core-files", "no shared core file differs from the reference without an allow entry or a cherry-pick")


def ios_pin(config: Config, name: str, core: Path | None, pin: str | None, ios_repo: Path | None, ios_ref: str) -> tuple[str | None, str]:
    entry = next((p for p in config.pins if p.name == name), None)
    if entry is None or not entry.ios:
        return None, ""
    sources = []
    if ios_repo is not None and ios_repo.is_dir():
        sources.append((ios_repo, ios_ref, f"{ios_repo.name} {ios_ref}"))
    if core is not None and pin and has_object(core, pin):
        core_source = (core, pin, f"core pin {pin[:10]}")
        # The legacy core is a history-free copy whose gitlinks are stale iOS pins; the iOS repo is the truth there.
        sources.insert(0, core_source) if config.mode == "shared" else sources.append(core_source)
    for repo, ref, label in sources:
        sha = gitlink(repo, ref, entry.ios)
        if sha:
            return sha, label
    return None, ""


def tree_blobs(repo: Path, sha: str, prefix: str) -> dict[str, str]:
    args = ["ls-tree", "-r", sha] + ([prefix] if prefix else [])
    blobs = {}
    for line in git(repo, *args).splitlines():
        meta, path = line.split("\t", 1)
        if prefix:
            if not path.startswith(prefix + "/"):
                continue
            path = path[len(prefix) + 1:]
        blobs[path] = meta.split()[2]
    return blobs


def webrtc_differences(config: Config, mac_repo: Path, mac_sha: str, ios_repo: Path, ios_sha: str) -> list[str]:
    mac = tree_blobs(mac_repo, mac_sha, config.webrtc_mac_root)
    ios = tree_blobs(ios_repo, ios_sha, config.webrtc_ios_root)
    return sorted(p for p in mac.keys() & ios.keys() if mac[p] != ios[p] and p.lower().endswith(SOURCE_SUFFIXES))


def default_ios_repo(root: Path) -> Path | None:
    env = os.environ.get("NANOGRAM_IOS_REPO")
    for candidate in ([Path(env)] if env else []) + [root.parent / "nanogram-ios"]:
        if (candidate / ".git").exists():
            return candidate
    return None


def default_mac_repo(root: Path) -> Path | None:
    env = os.environ.get("NANOGRAM_MAC_REPO")
    for candidate in ([Path(env)] if env else []) + [root.parent / "nanogram-macos"]:
        if (candidate / ".git").exists():
            return candidate
    return None


def check_mac(root: Path, config: Config, today: datetime.date, release: bool = False, pin_override: str | None = None,
              ios_repo: Path | None = None, ios_ref: str = "main") -> Report:
    report = Report()
    core = root / config.core_path
    pin = pin_override or gitlink(root, "HEAD", config.core_path)
    if not pin:
        report.error("core-pin", f"no gitlink for {config.core_path} in HEAD")
        return report
    if not (core / ".git").exists() or not has_object(core, pin):
        report.error("core-pin", f"{config.core_path} is not checked out at {pin[:10]} (tools/dev/tg setup)")
        return report
    check_roots(report, "core-root", core, [pin], config.core_roots)

    ok, where = reachable_from_owner(core, pin, config.remote_owner)
    (report.ok if ok else report.error)("core-published", f"core pin {pin[:10]} " + (f"is on {where}" if ok else f"is unpublished: {where}"))
    for entry in config.pins:
        if not entry.mac:
            continue
        path = root / entry.mac
        sha = gitlink(root, "HEAD", entry.mac)
        if sha is None:
            report.warn("pin-" + entry.name, f"no gitlink for {entry.mac} in HEAD")
            continue
        if not (path / ".git").exists() or not has_object(path, sha):
            report.warn("pin-" + entry.name, f"{entry.mac} is not checked out at {sha[:10]}; published check skipped")
            continue
        if entry.external:
            report.ok("pin-" + entry.name, f"{sha[:10]} is a third-party pin; published check skipped")
            continue
        ok, where = reachable_from_owner(path, sha, config.remote_owner)
        (report.ok if ok else report.error)("pin-" + entry.name, f"{sha[:10]} " + (f"is on {where}" if ok else f"is unpublished: {where}"))

    status = git(core, "status", "--porcelain", "--untracked-files=no", check=False).strip()
    if status:
        (report.error if release else report.warn)(
            "core-clean", f"{config.core_path} has uncommitted edits ({len(status.splitlines())} path(s)); "
            + ("a release needs a clean core" if release else "commit them to iOS main first, then tg core-bump"))
    elif rev(core, "HEAD") != pin:
        report.warn("core-clean", f"{config.core_path} HEAD {rev(core, 'HEAD')[:10]} is not the recorded pin {pin[:10]}")
    else:
        report.ok("core-clean", "the core checkout is clean and at the pin")

    reference = rev(core, config.reference)
    lts = rev(core, config.lts_ref)
    if reference is None:
        report.warn("core-ancestry", f"{config.reference} is not in the core checkout (git -C {config.core_path} fetch origin main); "
                    "ancestry, lag and file checks skipped")
    else:
        core_ahead_and_behind(report, core, pin, reference, config, today, lts)

    mine = file_exists_at(core, pin, CONFIG_RELATIVE)
    if mine is not None:
        same = mine == (root / CONFIG_RELATIVE).read_text()
        (report.ok if same else report.error)("paths-file", f"{CONFIG_RELATIVE} " + ("matches the core's copy" if same else "differs from the copy at the pin; keep both repos identical"))

    ios_repo = ios_repo or default_ios_repo(root)
    for entry in config.pins:
        if not entry.ios or not entry.mac or entry.name == "webrtc":
            continue
        mac_sha = gitlink(root, "HEAD", entry.mac)
        theirs, source = ios_pin(config, entry.name, core, pin, ios_repo, ios_ref)
        if mac_sha is None or theirs is None:
            report.warn("pin-equal-" + entry.name, "iOS pin not readable (no gitlink at the core pin and no --ios-repo); equality not checked")
        elif mac_sha == theirs:
            report.ok("pin-equal-" + entry.name, f"{entry.name} is {mac_sha[:10]} on both sides ({source})")
        else:
            soft_pin = entry.warn_until is not None and today <= entry.warn_until
            (report.warn if soft_pin else report.error)(
                "pin-equal-" + entry.name, f"{entry.name} differs: Mac {mac_sha[:10]}, iOS {theirs[:10]} ({source}); bring them to one SHA"
                + (f" (warning until {entry.warn_until})" if soft_pin else ""))

    web = next((p for p in config.pins if p.name == "webrtc"), None)
    if web:
        mac_sha = gitlink(root, "HEAD", web.mac)
        theirs, source = ios_pin(config, "webrtc", core, pin, ios_repo, ios_ref)
        mac_repo = root / web.mac
        ios_checkout = (ios_repo / web.ios) if ios_repo else None
        if not (mac_sha and theirs and (mac_repo / ".git").exists() and has_object(mac_repo, mac_sha)):
            report.warn("webrtc", "WebRTC trees not readable (Mac tg_owt checkout or the iOS webrtc pin missing); skipped")
        elif not (ios_checkout and (ios_checkout / ".git").exists() and has_object(ios_checkout, theirs)):
            report.warn("webrtc", f"iOS webrtc {theirs[:10]} not in a local checkout (pass --ios-repo with third-party/webrtc/webrtc initialised); skipped")
        else:
            differing = webrtc_differences(config, mac_repo, mac_sha, ios_checkout, theirs)
            open_files = [p for p in differing if not is_allowed(config, "webrtc", p, today)]
            expired = [a for a in config.allows if a.scope == "webrtc" and a.until and today > a.until]
            if open_files:
                shown = ", ".join(open_files[:8]) + (f" and {len(open_files) - 8} more" if len(open_files) > 8 else "")
                report.error("webrtc", f"{len(open_files)} shared WebRTC file(s) differ without an allow entry: {shown}")
            else:
                report.ok("webrtc", f"{len(differing)} differing WebRTC file(s), all allow-listed (tg_owt {mac_sha[:10]}, iOS {theirs[:10]})")
            for allow in expired:
                report.warn("webrtc-allow", f"allow entry {allow.prefix} expired on {allow.until}: {allow.reason}")
    return report


def ios_pins_published(report: Report, root: Path, config: Config, ref: str = "HEAD", base: str | None = None) -> None:
    for entry in config.pins:
        if not entry.ios or entry.external:
            continue
        sha = gitlink(root, ref, entry.ios)
        if sha is None or (base and gitlink(root, base, entry.ios) == sha):
            continue
        path = root / entry.ios
        if not (path / ".git").exists() or not has_object(path, sha):
            report.warn("pin-" + entry.name, f"{sha[:10]} cannot be checked: {entry.ios} is not checked out at it")
            continue
        ok, where = reachable_from_owner(path, sha, config.remote_owner)
        if ok:
            report.ok("pin-" + entry.name, f"{sha[:10]} is on {where}")
        elif entry.name in ("tgcalls", "rlottie", "tlottie"):
            report.error("pin-" + entry.name, f"{sha[:10]} is unpublished ({where}); a clone could not build. Push the submodule first")
        else:
            report.warn("pin-" + entry.name, f"{sha[:10]} is not on a {config.remote_owner} remote ({where})")


def check_ios(root: Path, config: Config, mac_repo: Path | None = None, revs: list[str] | None = None) -> Report:
    report = Report()
    check_roots(report, "history-root", root, revs or ["HEAD"], config.repo_roots.get("ios", []))
    ios_pins_published(report, root, config)
    mac_repo = mac_repo or default_mac_repo(root)
    if mac_repo is not None:
        for entry in config.pins:
            if entry.name == "webrtc" or not entry.ios or not entry.mac or entry.external:
                continue
            ours = gitlink(root, "HEAD", entry.ios)
            theirs = None
            for ref in ("nanogram/integration", "HEAD"):
                theirs = gitlink(mac_repo, ref, entry.mac)
                if theirs:
                    break
            if ours and theirs and ours != theirs:
                report.warn("pin-equal-" + entry.name, f"{entry.name} is {ours[:10]} here and {theirs[:10]} on the Mac; "
                            "never blocks iOS, the Mac side fails its own check until it takes the same SHA")
    return report


def touches_shared(root: Path, config: Config, base: str, head: str) -> list[str]:
    names = git(root, "diff", "--name-only", "--no-renames", base, head, check=False).split("\n")
    return sorted(p for p in names if p and any(covers(s, p) for s in config.shares))


def parse_push_refs(text: str) -> list[tuple[str, str, str, str]]:
    return [tuple(line.split()) for line in text.splitlines() if len(line.split()) == 4]  # type: ignore[misc]


def push_hook(root: Path, remote: str, stdin_text: str, today: datetime.date) -> int:
    if os.environ.get("TG_PRE_PUSH") == "0" or os.environ.get("TG_PARITY") == "0":
        return 0
    config = load_config(root)
    is_mac = (root / config.core_path / ".git").exists()
    report = Report()
    for local_ref, local_sha, remote_ref, remote_sha in parse_push_refs(stdin_text):
        if local_sha == ZERO_SHA or local_ref.startswith("refs/tags/"):
            continue
        if is_mac:
            pin = gitlink(root, local_sha, config.core_path)
            core = root / config.core_path
            if pin and has_object(core, pin):
                check_roots(report, "core-root", core, [pin], config.core_roots)
        else:
            check_roots(report, "history-root", root, [local_sha], config.repo_roots.get("ios", []))
            known = remote_sha != ZERO_SHA and has_object(root, remote_sha)
            ios_pins_published(report, root, config, local_sha, remote_sha if known else None)
            if known:
                shared = touches_shared(root, config, remote_sha, local_sha)
                if shared:
                    report.warn("shared-paths", f"this push changes {len(shared)} path(s) the Mac shares (e.g. {shared[0]}); "
                                "run tools/dev/tg core-bump on the Mac side the same day")
    for line in report.lines():
        if not line.startswith("ok:"):
            print("parity: " + line, file=sys.stderr if line.startswith("error") else sys.stdout)
    if report.failed:
        print("parity: push stopped (skip once with: git push --no-verify)", file=sys.stderr)
        return 1
    return 0


def suggest_allow(root: Path, config: Config, ios_repo: Path | None, ios_ref: str) -> list[str]:
    web = next(p for p in config.pins if p.name == "webrtc")
    core = root / config.core_path
    pin = gitlink(root, "HEAD", config.core_path)
    mac_sha = gitlink(root, "HEAD", web.mac)
    theirs, _ = ios_pin(config, "webrtc", core, pin, ios_repo or default_ios_repo(root), ios_ref)
    ios_checkout = (ios_repo or default_ios_repo(root)) / web.ios
    return [f"allow webrtc {p} | TODO reason" for p in webrtc_differences(config, root / web.mac, mac_sha, ios_checkout, theirs)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    default_root = Path(__file__).resolve().parents[3]
    for name in ("check", "fast", "roots", "push", "suggest-allow"):
        p = sub.add_parser(name)
        p.add_argument("--root", type=Path, default=default_root)
        p.add_argument("--today", type=datetime.date.fromisoformat, default=datetime.date.today())
        if name in ("check", "suggest-allow"):
            p.add_argument("--ios-repo", type=Path)
            p.add_argument("--ios-ref", default="main")
        if name == "check":
            p.add_argument("--release", action="store_true")
            p.add_argument("--pin")
        if name == "fast":
            p.add_argument("--mac-repo", type=Path)
        if name == "roots":
            p.add_argument("--config", type=Path)
            p.add_argument("--side", default="mac-core", choices=("mac-core", "ios"))
            p.add_argument("revs", nargs="+")
        if name == "push":
            p.add_argument("remote")
            p.add_argument("url", nargs="?")
    args = parser.parse_args(argv)
    try:
        root = args.root.resolve()
        if args.command == "push":
            return push_hook(root, args.remote, sys.stdin.read(), args.today)
        config = load_config(root, getattr(args, "config", None))
        if args.command == "suggest-allow":
            print("\n".join(suggest_allow(root, config, args.ios_repo, args.ios_ref)))
            return 0
        if args.command == "roots":
            report = Report()
            allowed = config.core_roots if args.side == "mac-core" else config.repo_roots.get("ios", [])
            repo = root / config.core_path if args.side == "mac-core" else root
            check_roots(report, "roots", repo, args.revs, allowed)
        elif args.command == "fast":
            report = check_ios(root, config, args.mac_repo)
        else:
            if not (root / config.core_path / ".git").exists():
                report = check_ios(root, config)
            else:
                report = check_mac(root, config, args.today, args.release, args.pin, args.ios_repo, args.ios_ref)
    except ParityError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    for line in report.lines():
        print(line, file=sys.stderr if line.startswith("error") else sys.stdout)
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
