#!/usr/bin/env python3
"""Drift check for native-library versions and build flags.

tools/dev/native/native-libs.json is the single reference for what both apps build into their native layer
(FFmpeg, opus, libvpx, dav1d, libwebp, libjpeg-turbo, OpenH264, TDLib, Rust, FlatBuffers, libyuv, ...). The same
file lives, byte for byte, in the iOS repo (Bazel) and the Mac repo (Xcode + core-xprojects scripts). Each library
lists *probes*: a file in the repo plus a pattern that reads the real value out of the build files each app
actually uses. The check fails when

  * a probe finds a value that differs from the file (someone bumped a library on one side only),
  * the two sides' values differ and the difference is not listed under "known_differences" with a reason,
  * the sibling repo's copy of this file differs (only when --sibling is given or found next to this repo).

Usage (from either repo root):  python3 tools/dev/native/check_native_libs.py [--sibling PATH] [--dump] [--json]
Exit status: 0 ok, 1 drift. --dump prints what this repo's build files say today (used to update the file).
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "native-libs.json"
FLAG_TOKEN = re.compile(
    r"(?<![\w$-])(--(?:enable|disable|with|without)-[A-Za-z0-9_\-]+(?:=[^\s\"'\\]*)?|--size-limit=[^\s\"']+"
    r"|--buildtype=[^\s\"']+|--default-library=[^\s\"']+|-D[A-Za-z0-9_]+=[^\s\"'\\]+|--target-os=\S+|--enable-cross-compile)")


def repo_side(root: Path) -> str:
    if (root / "MODULE.bazel").is_file():
        return "ios"
    if (root / "core-xprojects").is_dir():
        return "mac"
    raise SystemExit(f"{root} is neither the iOS nor the Mac repo")


def _read(root: Path, probe: dict) -> tuple[Path | None, str]:
    pattern = probe["file"]
    matches = sorted(glob.glob(str(root / pattern)))
    if not matches:
        return None, ""
    path = Path(matches[0])
    return path, path.read_text(errors="replace")


def _normalise(token: str) -> str:
    if "=" in token and "," in token.split("=", 1)[1]:
        key, values = token.split("=", 1)
        return key + "=" + ",".join(sorted(v for v in values.split(",") if v))
    return token


def run_probe(root: Path, probe: dict) -> object:
    """The value a probe reads from this repo, or None when the file or pattern is missing."""
    path, text = _read(root, probe)
    if path is None:
        return None
    kind = probe["kind"]
    if kind == "sha256":
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if kind == "filename":
        match = re.search(probe["regex"], path.name)
        return match.group(1) if match else None
    if "region" in probe:
        start, end = probe["region"]
        begin = re.search(start, text, re.M)
        if not begin:
            return None
        stop = re.search(end, text[begin.end():], re.M)
        text = text[begin.start(): begin.end() + (stop.end() if stop else len(text))]
    if kind == "flags":
        tokens = {_normalise(t) for t in FLAG_TOKEN.findall(text)}
        # A script that sources a shared flag list names that file (and its region) under "also".
        for extra in probe.get("also", []):
            extra_path, extra_text = _read(Path(root), extra)
            if extra_path is None:
                return None
            if "region" in extra:
                begin = re.search(extra["region"][0], extra_text, re.M)
                if not begin:
                    return None
                stop = re.search(extra["region"][1], extra_text[begin.end():], re.M)
                extra_text = extra_text[begin.start(): begin.end() + (stop.end() if stop else len(extra_text))]
            tokens |= {_normalise(t) for t in FLAG_TOKEN.findall(extra_text)}
        return sorted(tokens)
    match = re.search(probe["regex"], text, re.M)
    if not match:
        return None
    return ".".join(match.groups()) if len(match.groups()) > 1 else match.group(1)


def load(data_path: Path = DATA) -> dict:
    return json.loads(data_path.read_text())


def check(root: Path, data: dict) -> list[str]:
    side = repo_side(root)
    problems = []
    allowed = data.get("known_differences", {})
    for name, lib in data["libs"].items():
        observed: dict[str, dict[str, object]] = {}
        for probe in lib.get("probes", {}).get(side, []):
            value = run_probe(root, probe)
            what = probe["what"]
            observed.setdefault(what, {})[probe["id"]] = value
            expected = lib.get(what, {}).get(side, lib.get(what, {}).get("shared"))
            if value is None:
                problems.append(f"{name}.{what}: probe {probe['id']} found nothing in {probe['file']} ({side})")
            elif expected is None:
                problems.append(f"{name}.{what}: no expected value for {side} in native-libs.json")
            elif value != expected:
                problems.append(f"{name}.{what} ({side}, {probe['id']}): build files say {value!r}, native-libs.json says {expected!r}")
        # Both sides must agree unless the difference is listed with a reason.
        for what in ("version", "sha256", "flags"):
            entry = lib.get(what)
            if not isinstance(entry, dict) or "shared" in entry:
                continue
            if "ios" in entry and "mac" in entry and entry["ios"] != entry["mac"] and f"{name}.{what}" not in allowed:
                problems.append(f"{name}.{what}: iOS and Mac differ and the difference is not under known_differences")
        for key in allowed:
            lib_name, _, what = key.partition(".")
            entry = data["libs"].get(lib_name, {}).get(what)
            if lib_name == name and isinstance(entry, dict) and "shared" in entry:
                problems.append(f"known_differences lists {key} but both sides share one value: remove the entry")
    return problems


def compare_sibling(sibling: Path) -> list[str]:
    other = sibling / "tools/dev/native/native-libs.json"
    if not other.is_file():
        return [f"sibling repo {sibling} has no tools/dev/native/native-libs.json"]
    if other.read_bytes() != DATA.read_bytes():
        return [f"native-libs.json differs from {other}: the two copies must be identical"]
    return []


def dump(root: Path, data: dict) -> dict:
    side = repo_side(root)
    out = {}
    for name, lib in data["libs"].items():
        for probe in lib.get("probes", {}).get(side, []):
            out.setdefault(name, {}).setdefault(probe["what"], {})[probe["id"]] = run_probe(root, probe)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=HERE.parents[2])
    parser.add_argument("--sibling", type=Path)
    parser.add_argument("--dump", action="store_true")
    args = parser.parse_args(argv)
    data = load()
    if args.dump:
        print(json.dumps(dump(args.root, data), indent=2, sort_keys=True))
        return 0
    problems = check(args.root, data)
    sibling = args.sibling
    if sibling is None:
        for guess in ("nanogram-ios", "nanogram-macos"):
            candidate = args.root.parent / guess
            if candidate.is_dir() and candidate.resolve() != args.root.resolve():
                sibling = candidate
    if sibling is not None:
        problems += compare_sibling(sibling)
    for line in problems:
        print("native-libs drift:", line)
    if not problems:
        print(f"native-libs ok ({repo_side(args.root)}): {len(data['libs'])} libraries, "
              f"{len(data.get('known_differences', {}))} listed differences")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
