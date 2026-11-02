"""Checks that our settings really reached every compile: on the build log and on the built app.

A green build can still ship x86_64 slices or objects for an old macOS when a setting does not reach
a target (SwiftPM packages, workspace subprojects). These checks look at what the compilers were
actually told and at what ended up in the bundle.
"""
from __future__ import annotations

import argparse
import plistlib
import re
import shlex
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

MIN_OS = "15.0"
ALLOWED_ARCHS = ("arm64", "air64")
COMPILERS = {"clang", "clang++", "swiftc", "swift-frontend", "metal", "ld"}
CHECKED_ACTIONS = ("CompileC", "SwiftDriver", "SwiftCompile", "CompileMetalFile", "Ld")
MACHO_MAGICS = {
    bytes.fromhex("cffaedfe"), bytes.fromhex("feedfacf"),
    bytes.fromhex("cefaedfe"), bytes.fromhex("feedface"),
    bytes.fromhex("cafebabe"), bytes.fromhex("bebafeca"),
}
TARGET_RE = re.compile(r"\(in target '([^']+)' from project '([^']+)'\)")
TRIPLE_RE = re.compile(r"^([a-z0-9_]+)-apple-macos([0-9.]+)$")
X86_RE = re.compile(r"\bx86_64\b")


class _Problems:
    """Collects problems keyed by message, remembering which targets hit each one."""

    def __init__(self) -> None:
        self._targets: OrderedDict[str, list[str]] = OrderedDict()

    def add(self, message: str, target: str) -> None:
        targets = self._targets.setdefault(message, [])
        if target not in targets:
            targets.append(target)

    def render(self) -> list[str]:
        lines = []
        for message, targets in self._targets.items():
            shown = ", ".join(f"'{t}'" for t in targets[:5])
            more = f" (+{len(targets) - 5} more)" if len(targets) > 5 else ""
            lines.append(f"{message} in target {shown}{more}")
        return lines


def _tool_and_args(line: str) -> tuple[str, list[str]] | None:
    try:
        tokens = shlex.split(line)
    except ValueError:
        tokens = line.split()
    if not tokens:
        return None
    if tokens[0] == "builtin-SwiftDriver" and len(tokens) > 2:
        tokens = tokens[2:]
    tool = Path(tokens[0]).name
    if tool not in COMPILERS:
        return None
    return tool, tokens[1:]


def _expand_response_files(args: list[str]) -> list[str]:
    expanded = []
    for arg in args:
        path = Path(arg[1:]) if arg.startswith("@") else None
        if path is not None and path.suffix == ".resp" and path.is_file():
            try:
                expanded.extend(shlex.split(path.read_text(errors="replace")))
            except ValueError:
                expanded.extend(path.read_text(errors="replace").split())
        else:
            expanded.append(arg)
    return expanded


def _targets_of(args: list[str]) -> list[str]:
    return [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-target"]


def _optimization(args: list[str]) -> str | None:
    levels = [a for a in args if re.fullmatch(r"-O[0-9sz]?|-Ofast", a)]
    return levels[-1] if levels else None


def _blocks(log: str):
    action, label = None, "?"
    for raw in log.splitlines():
        if raw and not raw[0].isspace():
            action = raw.split(" ", 1)[0]
            match = TARGET_RE.search(raw)
            label = match.group(1) if match else "?"
            continue
        parsed = _tool_and_args(raw.strip())
        if parsed is not None and action is not None:
            yield action, label, parsed[0], parsed[1]


def _is_successful_xcodebuild_log(log: str) -> bool:
    return ("Command line invocation:" in log and "Build settings from command line:" in log
            and "** BUILD SUCCEEDED **" in log)


def check_log(log: str, release: bool = False, min_os: str = MIN_OS) -> list[str]:
    """Problems found in an xcodebuild log; empty when every compile is arm64 for macOS `min_os`."""
    problems = _Problems()
    seen = 0
    for action, label, tool, raw_args in _blocks(log):
        args = _expand_response_files(raw_args)
        triples = _targets_of(args)
        if action not in CHECKED_ACTIONS and not triples:
            continue
        seen += 1
        if not triples:
            problems.add(f"{action}: {tool} has no -target", label)
        wrong_arch = False
        for triple in triples:
            match = TRIPLE_RE.match(triple)
            if not match:
                problems.add(f"unexpected -target {triple}", label)
                wrong_arch = True
                continue
            arch, version = match.groups()
            if arch not in ALLOWED_ARCHS:
                problems.add(f"compiled for {triple} (want arm64-apple-macos{min_os})", label)
                wrong_arch = True
            elif version != min_os:
                problems.add(f"compiled for {triple} (want {arch}-apple-macos{min_os})", label)
        if not wrong_arch and any(X86_RE.search(a) for a in args):
            problems.add(f"{action}: {tool} command mentions x86_64", label)
        if release and action == "CompileC":
            level = _optimization(args)
            if level != "-O3":
                problems.add(f"C compile at {level or 'unknown optimization'} (want -O3)", label)
        if release and action == "Ld" and "-flto=thin" not in args:
            problems.add("link without -flto=thin", label)
    if seen == 0:
        # A no-change rebuild compiles nothing; accept it only when the log is recognisably xcodebuild's own.
        if _is_successful_xcodebuild_log(log):
            return []
        return ["no compile or link commands found in the log (was it an xcodebuild log of a real build?)"]
    return problems.render()


def _is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def _archs(path: Path) -> list[str] | None:
    result = subprocess.run(["lipo", "-archs", str(path)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    return result.stdout.split()


def _minos(path: Path) -> list[str]:
    out = subprocess.run(["otool", "-l", str(path)], capture_output=True, text=True, check=False).stdout
    return re.findall(r"^\s*minos\s+(\S+)", out, re.MULTILINE)


def find_app(products: Path) -> Path:
    """The app among a build's products: the .app that embeds an app extension (the share extension)."""
    apps = sorted(p for p in Path(products).glob("*.app") if any((p / "Contents" / "PlugIns").glob("*.appex")))
    if len(apps) != 1:
        raise FileNotFoundError(f"expected one app with an extension in {products}, found {len(apps)}")
    return apps[0]


def main_executable(app: Path) -> Path:
    with (app / "Contents" / "Info.plist").open("rb") as handle:
        name = plistlib.load(handle)["CFBundleExecutable"]
    return app / "Contents" / "MacOS" / name


def check_binary(app: Path, min_os: str = MIN_OS) -> list[str]:
    """Problems in a built .app: any Mach-O that is not arm64-only, a main binary not built for `min_os`,
    or a Metal shader shipped as source."""
    app = Path(app)
    if not app.is_dir():
        return [f"{app} does not exist"]
    problems = []
    for path in sorted(p for p in app.rglob("*") if p.is_file() and not p.is_symlink()):
        if path.suffix == ".metal":
            problems.append(f"{path.relative_to(app.parent)}: Metal source shipped instead of a compiled metallib "
                            "(a package copies it as a resource; see XCODE27.md item 3)")
            continue
        if not _is_macho(path):
            continue
        archs = _archs(path)
        if archs is None:
            continue
        if archs != ["arm64"]:
            problems.append(f"{path.relative_to(app.parent)}: architectures {' '.join(archs)} (want arm64)")
    main = main_executable(app)
    versions = sorted(set(_minos(main)))
    if versions != [min_os]:
        problems.append(f"{main.relative_to(app.parent)}: minos {' '.join(versions) or 'missing'} (want {min_os})")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--products", type=Path, help="Build/Products/<configuration>; checks the app found there")
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args(argv)
    problems = []
    if args.log:
        problems += check_log(args.log.read_text(errors="replace"), release=args.release)
    app = args.app
    if args.products:
        try:
            app = find_app(args.products)
        except FileNotFoundError as error:
            problems.append(str(error))
    if app:
        print(f"buildcheck: checking {app}")
        problems += check_binary(app)
    for problem in problems:
        print(f"buildcheck: {problem}", file=sys.stderr)
    if not problems:
        print("buildcheck: ok")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
