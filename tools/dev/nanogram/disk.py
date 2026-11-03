"""`tg clean` and `tg prune`: build files under the cache root (~/.cache/nanogram-macos), listed and bounded.

Only DerivedData directories, SwiftPM scratch directories, the native-library cache, the compilation cache and
tmp are ever removed; anything else under the cache root (tools, keys, logs) is listed and kept. Nothing a running
build holds (its checkout's buildlock) and nothing of the current checkout is removed by `prune`.
"""
from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from . import checkoutlock, config, fwcache

Kind = Literal["derived-data", "swiftpm-scratch", "frameworks", "compilation-cache", "tmp", "other"]
DAY = 86400
TMP_MAX_AGE = 6 * 3600
RECENT = 2 * 3600
DEFAULT_MAX_GB = 40
EVICTION_ORDER: tuple[Kind, ...] = ("swiftpm-scratch", "derived-data", "compilation-cache")
STALE_KINDS: tuple[Kind, ...] = ("derived-data", "swiftpm-scratch")
PROTECTED_NAMES = ("sparkle-ed25519", "sparkle_ed25519", "launch-home")


@dataclass(frozen=True)
class Item:
    path: Path
    kind: Kind
    owner: Path | None
    size: int
    last_used: float
    orphan: bool
    locked: bool
    current: bool


def kind_of(path: Path) -> Kind:
    name = path.name
    if not path.is_dir() or path.is_symlink() or name in PROTECTED_NAMES:
        return "other"
    if name.startswith("DerivedData"):
        return "derived-data"
    if name.startswith("spm-") or name == "swiftpm":
        return "swiftpm-scratch"
    if name == "frameworks":
        return "frameworks"
    if name == "CompilationCache":
        return "compilation-cache"
    if name == "tmp":
        return "tmp"
    return "other"


def disk_usage(path: Path) -> int:
    result = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True, check=False)
    try:
        return int(result.stdout.split()[0]) * 1024
    except (IndexError, ValueError):
        return 0


def last_used(path: Path) -> float:
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


lock_file = checkoutlock.lock_file
is_locked = checkoutlock.is_locked


def workspace_owner(derived: Path) -> Path | None:
    try:
        with (derived / "info.plist").open("rb") as handle:
            workspace = plistlib.load(handle).get("WorkspacePath")
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    return Path(workspace).parent if workspace else None


def named_owner(derived: Path, checkouts: Path) -> Path:
    suffix = derived.name.removeprefix("DerivedData").lstrip("-")
    return checkouts / (f"{config.CHECKOUT_PREFIX}-{suffix}" if suffix else config.CHECKOUT_PREFIX)


def inventory(cache_dir: Path, current_derived: Path, checkouts: Path | None = None) -> list[Item]:
    cache_dir = Path(cache_dir)
    checkouts = Path(checkouts or config.ROOT.parent)
    if not cache_dir.is_dir():
        return []
    items = []
    for path in sorted(cache_dir.iterdir(), key=lambda p: p.name.lower()):
        kind = kind_of(path)
        owner, orphan, locked = None, False, False
        if kind == "derived-data":
            owner = workspace_owner(path)
            named = named_owner(path, checkouts)
            candidates = [c for c in (owner, named) if c is not None]
            orphan = not any(c.is_dir() for c in candidates)
            locked = any(is_locked(lock_file(cache_dir, c)) for c in candidates)
            owner = owner or named
        items.append(Item(path, kind, owner, disk_usage(path), last_used(path), orphan, locked,
                          path.resolve() == Path(current_derived).resolve()))
    return items


def _inside_cache(path: Path) -> bool:
    cache = Path(config.CACHE_DIR).resolve()
    resolved = path.parent.resolve() / path.name
    return resolved != cache and resolved.is_relative_to(cache)


def _tmp_children(item: Item, now: float) -> list[Item]:
    stale = []
    try:
        children = sorted(item.path.iterdir())
    except OSError:
        return []
    for child in children:
        used = last_used(child)
        if child.name.startswith("frameworks-") and now - used > TMP_MAX_AGE:
            stale.append(Item(child, "tmp", None, disk_usage(child), used, False, False, False))
    return stale


def plan_prune(items: list[Item], max_total: int, stale_days: int = 7,
               now: float | None = None) -> dict[Path, str]:
    now = time.time() if now is None else now
    actions: dict[Path, str] = {}
    removed: set[Path] = set()
    for item in items:
        if item.current:
            actions[item.path] = "keep: current checkout"
        elif item.locked:
            actions[item.path] = "keep: build running"
        elif item.kind == "other":
            actions[item.path] = "keep: not a build cache"
        elif item.kind == "derived-data" and item.orphan:
            actions[item.path] = "remove: checkout gone"
        elif item.kind in STALE_KINDS and now - item.last_used > stale_days * DAY:
            actions[item.path] = f"remove: unused {int((now - item.last_used) // DAY)} days"
        elif item.kind == "frameworks":
            actions[item.path] = f"keep: LRU-capped at {fwcache.max_bytes() / 1024**3:.0f} GB"
        else:
            actions[item.path] = "keep"
        if actions[item.path].startswith("remove"):
            removed.add(item.path)
        if item.kind == "tmp" and not item.current:
            for child in _tmp_children(item, now):
                actions[child.path] = "remove: framework build scratch older than 6 hours"
    total = sum(i.size for i in items if i.path not in removed)
    for kind in EVICTION_ORDER:
        candidates = sorted((i for i in items if i.kind == kind and i.path not in removed
                             and not i.current and not i.locked), key=lambda i: i.last_used)
        for item in candidates:
            if total <= max_total:
                break
            if now - item.last_used < RECENT:
                actions[item.path] = "keep: used in the last 2 hours"
                continue
            actions[item.path] = "remove: over the cap"
            removed.add(item.path)
            total -= item.size
    return actions


def prune(items: list[Item], max_total: int, stale_days: int = 7, dry_run: bool = False) -> list[Item]:
    actions = plan_prune(items, max_total, stale_days)
    known = {i.path: i for i in items}
    targets = []
    for path, action in actions.items():
        if not action.startswith("remove"):
            continue
        item = known.get(path) or Item(path, "tmp", None, disk_usage(path), last_used(path), False, False, False)
        targets.append(item)
    outside = [str(i.path) for i in targets if not _inside_cache(i.path)]
    if outside:
        raise config.ConfigError(f"refusing to remove paths outside {config.CACHE_DIR}: {', '.join(outside)}")
    protected = [str(i.path) for i in targets if i.path.name in PROTECTED_NAMES]
    if protected:
        raise config.ConfigError(f"refusing to remove protected paths: {', '.join(protected)}")
    if dry_run:
        return targets
    for item in targets:
        shutil.rmtree(item.path, ignore_errors=True)
    if (Path(config.CACHE_DIR) / "frameworks").is_dir():
        fwcache.prune(fwcache.max_bytes(), keep=set())
    return targets


def owned_derived_data(derived: Path, cache_dir: Path) -> bool:
    if derived.is_symlink() or not derived.name.startswith("DerivedData"):
        return False
    return derived.resolve().parent == Path(cache_dir).resolve()


def require_owned_derived_data() -> Path:
    derived = Path(config.DERIVED_DATA)
    if not owned_derived_data(derived, Path(config.CACHE_DIR)):
        raise config.ConfigError(f"{derived} is not a DerivedData* directory directly in {config.CACHE_DIR}; "
                                 "tg clean removes nothing outside it")
    return derived


def clean(root: Path, everything: bool) -> int:
    root = Path(root)
    derived = require_owned_derived_data()
    targets = [derived if everything else derived / "Build", root / "build-output" / "apps"]
    freed = 0
    for target in targets:
        if target.exists():
            freed += disk_usage(target)
            shutil.rmtree(target, ignore_errors=True)
    return freed


def gigabytes(size: int) -> str:
    return f"{size / 1024**3:.1f} GB"


def max_total_bytes(max_gb: float | None) -> int:
    value = max_gb if max_gb is not None else float(os.environ.get("NANOGRAM_CACHE_MAX_GB", DEFAULT_MAX_GB))
    return int(value * 1024**3)


def print_table(items: list[Item], actions: dict[Path, str], max_total: int) -> None:
    now = time.time()
    print(f"{'kind':<18} {'size':>8}  {'last used':>9}  {'path':<34} {'owner':<28} action")
    for item in items:
        owner = item.owner.name if item.owner else "-"
        used = f"{(now - item.last_used) / DAY:.1f} d"
        print(f"{item.kind:<18} {gigabytes(item.size):>8}  {used:>9}  {item.path.name:<34} {owner:<28} "
              f"{actions.get(item.path, 'keep')}")
        for child, action in actions.items():
            if child.parent == item.path:
                print(f"{'':<18} {'':>8}  {'':>9}  {item.path.name + '/' + child.name:<34} {'-':<28} {action}")
    total = sum(i.size for i in items)
    freed = sum(i.size for i in items if actions.get(i.path, "").startswith("remove"))
    print(f"total {gigabytes(total)} under {config.CACHE_DIR} (cap {gigabytes(max_total)}); "
          f"removing {gigabytes(freed)} leaves {gigabytes(total - freed)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg")
    commands = parser.add_subparsers(dest="command", required=True)
    clean_parser = commands.add_parser("clean")
    clean_parser.add_argument("--all", action="store_true")
    prune_parser = commands.add_parser("prune")
    prune_parser.add_argument("--dry-run", action="store_true")
    prune_parser.add_argument("--max-gb", type=float)
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.command == "clean":
            require_owned_derived_data()
            before = disk_usage(Path(config.DERIVED_DATA)) if Path(config.DERIVED_DATA).exists() else 0
            print(f"==> {config.DERIVED_DATA}: {gigabytes(before)}")
            with checkoutlock.hold(checkoutlock.lock_path(), exclusive=True):
                freed = clean(config.ROOT, everything=args.all)
            after = disk_usage(Path(config.DERIVED_DATA)) if Path(config.DERIVED_DATA).exists() else 0
            print(f"==> freed {gigabytes(freed)}; {config.DERIVED_DATA}: {gigabytes(after)}")
            return 0
        max_total = max_total_bytes(args.max_gb)
        items = inventory(Path(config.CACHE_DIR), Path(config.DERIVED_DATA))
        print_table(items, plan_prune(items, max_total), max_total)
        removed = prune(items, max_total, dry_run=args.dry_run)
        verb = "would remove" if args.dry_run else "removed"
        print(f"==> {verb} {len(removed)} item(s), {gigabytes(sum(i.size for i in removed))}")
        return 0
    except config.ConfigError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
