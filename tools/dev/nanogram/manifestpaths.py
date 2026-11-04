"""Check that local SwiftPM dependency paths point at real packages.

Xcode resolves a `.package(path:)` that points at a directory without a Package.swift by looking up a package
with the same name elsewhere in the workspace. Three upstream manifests worked only through that accident (the
build log showed packages/Svg and submodules/BuildConfig being compiled instead of the path that was written).
It turns into a wrong build as soon as a core module gains a Package.swift of the same name.

Rule: every local dependency path in packages/*/Package.swift and submodules/*/Package.swift must resolve to a
directory that contains a Package.swift. A manifest must also not list two different directories with the same
last path component (SwiftPM derives the package identity from it).

Pure text analysis; nothing is built. `python3 tools/dev/nanogram/manifestpaths.py [--root ROOT]` exits 1 on a problem.
Paths into a submodule that is not checked out (empty directory, as in a fresh worktree) are skipped.
"""
import argparse
import re
import sys
from pathlib import Path

# `.package(name: "X", path: "../X")` and the `deps` tuple lists used by generated manifests: ("X", "../X").
PACKAGE_CALL = re.compile(r'\.package\(([^()]*?)\bpath:\s*"([^"]+)"')
DEP_TUPLE = re.compile(r'\(\s*"[A-Za-z0-9_+.-]+"\s*,\s*"(\.{1,2}/[^"]*)"\s*\)')


def manifests(root: Path) -> list[Path]:
    found: list[Path] = []
    for group in ("packages", "submodules"):
        base = root / group
        if base.is_dir():
            found += sorted(base.glob("*/Package.swift"))
    return found


def local_paths(text: str) -> list[str]:
    """Local dependency paths written in a manifest, in file order, without duplicates."""
    hits: list[tuple[int, str]] = []
    for match in PACKAGE_CALL.finditer(text):
        hits.append((match.start(), match.group(2)))
    for match in DEP_TUPLE.finditer(text):
        hits.append((match.start(), match.group(1)))
    seen: set[str] = set()
    ordered: list[str] = []
    for _, path in sorted(hits):
        if path not in seen:
            seen.add(path)
            ordered.append(path)
    return ordered


def check(root: Path) -> list[str]:
    root = root.resolve()
    missing_submodules = [prefix for prefix in submodule_prefixes(root)
                          if not Path(prefix).is_dir() or not any(Path(prefix).iterdir())]
    problems: list[str] = []
    for manifest in manifests(root):
        relative = manifest.relative_to(root).as_posix()
        identities: dict[str, str] = {}
        for path in local_paths(manifest.read_text(errors="replace")):
            target = Path(manifest.parent, path)
            resolved = Path(_normalize(target)).as_posix()
            if any((resolved + "/").startswith(prefix) for prefix in missing_submodules):
                continue
            if not Path(resolved).is_dir():
                problems.append(f"{relative}: path {path} does not exist")
                continue
            if not Path(resolved, "Package.swift").is_file():
                problems.append(f"{relative}: path {path} has no Package.swift "
                                "(Xcode would substitute a package of the same name)")
                continue
            identity = Path(resolved).name.lower()
            if identity in identities and identities[identity] != resolved:
                problems.append(f"{relative}: two different directories named {Path(resolved).name}: "
                                f"{identities[identity]} and {resolved}")
            identities.setdefault(identity, resolved)
    return problems


def submodule_prefixes(root: Path) -> list[str]:
    """Absolute directory prefixes (with a trailing slash) of the submodules listed in .gitmodules."""
    listing = root / ".gitmodules"
    if not listing.is_file():
        return []
    paths = re.findall(r"^\s*path\s*=\s*(\S+)\s*$", listing.read_text(errors="replace"), re.MULTILINE)
    return [(root / path).as_posix().rstrip("/") + "/" for path in paths]


def _normalize(path: Path) -> str:
    import os
    return os.path.normpath(str(path))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Local SwiftPM dependency paths must point at real packages.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args(argv)
    problems = check(args.root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if not problems:
        print("manifest paths: every local dependency path has a Package.swift")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
