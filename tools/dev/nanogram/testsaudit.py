#!/usr/bin/env python3
"""List the tools/tests regression runners and check, without compiling, that they still match the source.

tools/tests holds one folder per regression (171 today, 160 with a run.py). Most runners cut snippets out of the
production Swift by text anchors (`source.index('public func trimOpusFile')`, `block(s, marker)`) and compile
them in a temporary package, so they break silently when the code is renamed or reformatted. Neither `tg test` nor
`tg check` runs them. This script reads each run.py as Python (ast, nothing is executed), finds

  * the production files it reads (path literals and `root / 'a' / 'b'` chains that start at a known repo folder,
    resolved in this repository or in the iOS core, at the working tree or at the submodule pin),
  * the anchors it searches for (first argument of .index/.find/.rindex/.rfind, `'x' in source`, arguments of the
    runner's own helper functions whose parameter is called marker/anchor/needle..., and lists named *markers*),

and reports files that are gone, anchors found in none of the files, and how stale the runner is (last commit that
touched its folder against the newest commit that touched a source it reads).

A static check cannot tell every real break from an anchor that is built at run time, so read the output as a
to-do list for the combined build night, not as proof. Report only: exit status 0 unless --strict, and it is not
part of `tg check`.

  python3 -m nanogram.testsaudit [--root DIR] [--core DIR] [--only NAME] [--problems] [--json] [--strict]
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
import warnings
from dataclasses import dataclass, field
from pathlib import Path

KNOWN_TOP = ("packages/", "submodules/", "Telegram-Mac/", "core-xprojects/", "scripts/", "tools/", "nanogram/", "docs/",
             "Telegram.xcodeproj/", "third-party/")
ROOT_NAMES = {"root", "ROOT", "repo", "REPO", "submodule", "SUBMODULE", "core", "CORE"}
SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".h", ".c", ".cpp", ".hpp", ".plist", ".json", ".xcconfig", ".entitlements",
                   ".strings", ".sh", ".py", ".pbxproj")
SEARCH_METHODS = {"index", "find", "rindex", "rfind"}
ANCHOR_PARAMS = {"marker", "anchor", "needle", "start_marker", "end_marker", "signature", "startmarker", "endmarker"}
CORE_DIR = "submodules/telegram-ios"
MIN_ANCHOR = 3


@dataclass
class Runner:
    name: str
    runner: str | None
    candidates: list[str] = field(default_factory=list)
    anchors: list[str] = field(default_factory=list)
    resolved: dict[str, str] = field(default_factory=dict)
    unresolved: list[str] = field(default_factory=list)
    missing_anchors: list[str] = field(default_factory=list)
    last_touched: str = ""
    newest_source: str = ""

    @property
    def stale(self) -> bool:
        return bool(self.last_touched and self.newest_source and self.newest_source > self.last_touched)

    @property
    def problem(self) -> bool:
        return bool(self.unresolved or self.missing_anchors)


def looks_like_source_path(path: str) -> bool:
    return ("/" in path and not path.startswith("/") and path.startswith(KNOWN_TOP) and path.endswith(SOURCE_SUFFIXES)
            and "__" not in path and "*" not in path)


def chain_path(node: ast.AST, env: dict[str, str]) -> str | None:
    """`root / 'a' / 'b.swift'` as 'a/b.swift'; the head is a repo-like name or a variable assigned such a chain."""
    parts: list[ast.AST] = []
    current: ast.AST = node
    while isinstance(current, ast.BinOp) and isinstance(current.op, ast.Div):
        parts.append(current.right)
        current = current.left
    parts.append(current)
    parts.reverse()
    head = parts[0]
    if not isinstance(head, ast.Name):
        return None
    if head.id in env:
        prefix = [env[head.id]] if env[head.id] else []
    elif head.id in ROOT_NAMES:
        prefix = []
    else:
        return None
    constants = [p.value for p in parts[1:] if isinstance(p, ast.Constant) and isinstance(p.value, str)]
    if len(constants) != len(parts) - 1 or not constants:
        return None
    return "/".join(c.strip("/") for c in prefix + constants if c.strip("/"))


def div_chains(tree: ast.AST) -> list[str]:
    """Paths written as chains, e.g. `root / 'packages' / 'X' / 'file.swift'`, also through variables that were
    assigned a chain (`base = root / 'packages/X'`). Only chains that end in a source-like file name count."""
    env: dict[str, str] = {}
    assigns = [n for n in ast.walk(tree) if isinstance(n, ast.Assign) and len(n.targets) == 1
               and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.BinOp)]
    assigns.sort(key=lambda n: n.lineno)
    for _ in range(2):
        for node in assigns:
            resolved = chain_path(node.value, env)
            if resolved is not None:
                env[node.targets[0].id] = resolved
    inner = {id(node.left) for node in ast.walk(tree) if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div)}
    paths = []
    for node in ast.walk(tree):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div) and id(node) not in inner:
            joined = chain_path(node, env)
            if joined and joined.endswith(SOURCE_SUFFIXES):
                paths.append(joined)
    return paths


def loop_literals(tree: ast.AST) -> dict[str, list[str]]:
    """`for marker in ['a', 'b']` (also in comprehensions): loop variable -> the literal strings it takes."""
    values: dict[str, list[str]] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.For, ast.comprehension)) and isinstance(node.target, ast.Name) and isinstance(
                node.iter, (ast.List, ast.Tuple)):
            items = [e.value for e in node.iter.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
            if items:
                values.setdefault(node.target.id, []).extend(items)
    return values


def anchor_helpers(tree: ast.AST) -> dict[str, set[int]]:
    """Functions defined in the runner whose parameters are anchors: name -> positional indexes."""
    helpers: dict[str, set[int]] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.Lambda)):
            names = [a.arg for a in node.args.args]
            positions = {i for i, n in enumerate(names) if n.lower() in ANCHOR_PARAMS}
            if positions and isinstance(node, ast.FunctionDef):
                helpers[node.name] = positions
    return helpers


def extract(runner_source: str) -> tuple[list[str], list[str]]:
    """(source path candidates, anchors) of one run.py, in file order, without duplicates."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(runner_source)
    except (SyntaxError, ValueError):
        return [], []
    paths: list[str] = []
    anchors: list[str] = []
    helpers = anchor_helpers(tree)
    loop_values = loop_literals(tree)

    def literals(arg: ast.AST) -> list[str]:
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
            return [arg.value]
        if isinstance(arg, ast.Name):
            return loop_values.get(arg.id, [])
        return []

    for node in sorted((n for n in ast.walk(tree) if hasattr(n, "lineno")), key=lambda n: (n.lineno, n.col_offset)):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and looks_like_source_path(node.value):
            paths.append(node.value)
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in SEARCH_METHODS and node.args:
                anchors += literals(node.args[0])
            name = func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else ""
            for position in helpers.get(name, ()):
                if position < len(node.args):
                    anchors += literals(node.args[position])
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.In):
            if isinstance(node.left, ast.Constant) and isinstance(node.left.value, str) and isinstance(
                    node.comparators[0], (ast.Name, ast.Attribute)):
                anchors.append(node.left.value)
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and re.search(r"marker|anchor", t.id, re.I)
                                                 for t in node.targets):
            if isinstance(node.value, (ast.List, ast.Tuple)):
                anchors += [e.value for e in node.value.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
    paths += div_chains(tree)
    return unique(paths), unique(a for a in anchors if len(a.strip()) >= MIN_ANCHOR)


def unique(items) -> list[str]:
    seen: set[str] = set()
    result = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def git(repo: Path, *args: str) -> str | None:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    return result.stdout if result.returncode == 0 else None


class Sources:
    """Reads a path from this repository or from the iOS core (working tree, else the commit the superproject pins)."""

    def __init__(self, root: Path, core: Path | None = None):
        self.root = root
        self.core = core or root / CORE_DIR
        pin = git(root, "ls-tree", "HEAD", "--", CORE_DIR)
        self.pin = pin.split()[2] if pin and pin.split()[:2] == ["160000", "commit"] else None
        self.cache: dict[str, tuple[str, str] | None] = {}

    def locate(self, path: str) -> tuple[str, str] | None:
        """(label, text) for a repository path or a core path, or None when it exists nowhere."""
        if path in self.cache:
            return self.cache[path]
        found = None
        relative_core = path[len(CORE_DIR) + 1:] if path.startswith(CORE_DIR + "/") else path
        for label, base, relative in (("repo", self.root, path), ("core", self.core, relative_core)):
            target = base / relative
            if target.is_file():
                found = (f"{label}:{relative}", target.read_text(errors="replace"))
                break
        if found is None and self.pin and (self.core / ".git").exists():
            text = git(self.core, "show", f"{self.pin}:{relative_core}")
            if text is not None:
                found = (f"core@pin:{relative_core}", text)
        self.cache[path] = found
        return found

    def newest_commit_date(self, label: str) -> str:
        where, _, relative = label.partition(":")
        repo = self.root if where == "repo" else self.core
        if where == "repo" and relative.startswith(CORE_DIR + "/"):
            repo, relative = self.core, relative[len(CORE_DIR) + 1:]
        out = git(repo, "log", "-1", "--format=%cs", "--", relative) if (repo / ".git").exists() or where == "repo" else None
        return (out or "").strip()


def audit_runner(folder: Path, sources: Sources) -> Runner:
    runner_file = folder / "run.py"
    result = Runner(folder.name, str(runner_file) if runner_file.is_file() else None)
    result.last_touched = (git(sources.root, "log", "-1", "--format=%cs", "--", str(folder)) or "").strip()
    if not runner_file.is_file():
        return result
    result.candidates, result.anchors = extract(runner_file.read_text(errors="replace"))
    texts = []
    for path in result.candidates:
        located = sources.locate(path)
        if located is None:
            result.unresolved.append(path)
            continue
        label, text = located
        result.resolved[path] = label
        texts.append(text)
    if texts:
        joined = "\n".join(texts)
        result.missing_anchors = [a for a in result.anchors if a not in joined]
    dates = [sources.newest_commit_date(label) for label in result.resolved.values()]
    result.newest_source = max([d for d in dates if d], default="")
    return result


def audit(root: Path, only: str | None = None, core: Path | None = None) -> list[Runner]:
    sources = Sources(root, core)
    base = root / "tools" / "tests"
    folders = sorted(p for p in base.iterdir() if p.is_dir()) if base.is_dir() else []
    return [audit_runner(f, sources) for f in folders if not only or f.name == only]


def render(runners: list[Runner], problems_only: bool = False) -> list[str]:
    lines = []
    for r in runners:
        if problems_only and not (r.problem or r.stale):
            continue
        flags = []
        if r.runner is None:
            flags.append("no run.py")
        if r.stale:
            flags.append(f"stale: sources changed {r.newest_source}, runner {r.last_touched}")
        lines.append(f"{r.name}  [{r.last_touched or 'untracked'}]" + ("  " + "; ".join(flags) if flags else ""))
        for path in r.unresolved:
            lines.append(f"  source not found: {path}")
        for anchor in r.missing_anchors:
            lines.append(f"  anchor not found in any source: {anchor!r}")
    total = len(runners)
    stale = sum(1 for r in runners if r.stale)
    broken = sum(1 for r in runners if r.problem)
    without = sum(1 for r in runners if r.runner is None)
    lines.append(f"tools/tests: {total} folder(s), {without} without run.py, {broken} with a missing source or anchor, "
                 f"{stale} whose sources changed after the runner (static check; run them in the combined build)")
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--core", type=Path, help="another checkout of the iOS core (default: submodules/telegram-ios)")
    parser.add_argument("--only")
    parser.add_argument("--problems", action="store_true", help="list only runners with a missing source/anchor or stale ones")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(argv)
    runners = audit(args.root.resolve(), args.only, args.core.resolve() if args.core else None)
    if args.json:
        print(json.dumps([{**r.__dict__, "stale": r.stale} for r in runners], indent=1))
    else:
        print("\n".join(render(runners, args.problems)))
    return 1 if args.strict and any(r.problem for r in runners) else 0


if __name__ == "__main__":
    sys.exit(main())
