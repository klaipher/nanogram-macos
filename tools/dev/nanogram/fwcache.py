"""Content-addressed cache of the native libraries, shared by every checkout of this repository.

An entry is keyed by upstream's framework stamp (inputs, Xcode, deployment target, architectures, dependency
stamps) with the `rust=` line pinned to the toolchain the Rust libraries are really built with. It holds only
what the app build and dependent library builds read; restoring clones the files (APFS) into the checkout and
writes the checkout's own stamp so scripts/configure_frameworks.sh skips the library.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path

from . import config, frameworks

UNITS: tuple[str, ...] = tuple(frameworks.libraries()) + ("tlottie",)
EXTRA_OUTPUTS: dict[str, str] = {
    "wallet-engine": "packages/WalletEngine/wallet_engineFFI.xcframework",
    "mtproto-engine": "submodules/telegram-ios/submodules/MTProtoRustEngine/MTProtoEngineFFI.xcframework",
}
TOOLCHAIN_FILE = "submodules/telegram-ios/third-party/mtproto-engine/rust-toolchain.toml"
TLOTTIE_BUILD = "core-xprojects/tlottie/build"
TLOTTIE_LIBRARY = f"{TLOTTIE_BUILD}/libtlottie.a"
KEY_SCHEMA = "nanogram-fwcache=1\n"
RUST_LINE = re.compile(r"(?m)^rust=.*$")
META_SCHEMA = 1
PARTIAL_MAX_AGE = 3600
COPY_CHUNK = 400
DEFAULT_MAX_GB = 3
PAIR = re.compile(r'^\s*"\$\{SCRIPT_DIR\}/\.\./([^,"]+),\$\{SCRIPT_DIR\}/\.\./([^,"]+)"', re.MULTILINE)
TD_PAIR = ("submodules/telegram-ios/third-party/td/td", "submodules/telegram-ios/third-party/td/TdBinding/SharedHeaders/td")

STAMPS_SCRIPT = r"""
set -e
. "$1/framework-inputs.sh"
ROOT_ARG="$2"
OUT="$3"
shift 3
FRAMEWORK_XCODE_VERSION="${FRAMEWORK_XCODE_VERSION:-$(xcodebuild -version | tr '\n' ' ')}"
for UNIT in "$@"; do
    framework_stamp "$ROOT_ARG" "$UNIT" "$OUT" > "$OUT/$UNIT.tmp"
    mv "$OUT/$UNIT.tmp" "$OUT/$UNIT"
done
{
    echo "schema=$FRAMEWORK_STAMP_SCHEMA"
    echo "lib=tlottie"
    echo "xcode=$FRAMEWORK_XCODE_VERSION"
    echo "deployment=${MACOSX_DEPLOYMENT_TARGET:-default}"
    echo "archs=${ARCHS:-default}"
    echo "rust=$NANOGRAM_PINNED_RUST"
    echo "input:submodules/tlottie=$(framework_path_fingerprint "$ROOT_ARG/submodules/tlottie")"
    echo "input:core-xprojects/tlottie/build.sh=$(framework_path_fingerprint "$ROOT_ARG/core-xprojects/tlottie/build.sh")"
} > "$OUT/tlottie"
"""

OUTPUTS_SCRIPT = r"""
. "$1/framework-inputs.sh"
ROOT_ARG="$2"
shift 2
for UNIT in "$@"; do
    framework_required_outputs "$ROOT_ARG" "$UNIT" | sed "s|^|$UNIT	|" || exit 1
done
"""


def pinned_channel(root: Path) -> str:
    match = re.search(r'(?m)^channel\s*=\s*"([^"]+)"', (Path(root) / TOOLCHAIN_FILE).read_text())
    if not match:
        raise config.ConfigError(f"{TOOLCHAIN_FILE} names no toolchain channel")
    return match.group(1)


def rustup_path() -> str | None:
    bundled = config.RUSTUP_BIN / "rustup"
    return str(bundled) if bundled.exists() else shutil.which("rustup")


def pinned_rust(root: Path) -> str:
    rustup = rustup_path()
    if rustup is None:
        return "missing"
    try:
        channel = pinned_channel(root)
        result = subprocess.run([rustup, "run", channel, "rustc", "-V"], capture_output=True, text=True, check=False)
    except (OSError, config.ConfigError):
        return "missing"
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else "missing"


def xcode_version_line() -> str:
    out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout
    return out.replace("\n", " ")


def stamp_environment(base: Mapping[str, str] | None = None) -> dict[str, str]:
    env = frameworks.build_environment(config.BUILD_OUTPUT / "frameworks-timing.tsv",
                                       dict(os.environ if base is None else base))
    env.setdefault("FRAMEWORK_XCODE_VERSION", xcode_version_line())
    return env


def local_stamps(root: Path, env: Mapping[str, str], rust: str | None = None) -> dict[str, str]:
    root = Path(root)
    libraries = frameworks.libraries()
    run_env = dict(env)
    run_env["NANOGRAM_PINNED_RUST"] = rust if rust is not None else pinned_rust(root)
    with tempfile.TemporaryDirectory(prefix="nanogram-stamps-") as out:
        subprocess.run(["bash", "-c", STAMPS_SCRIPT, "bash", str(frameworks.SCRIPTS), str(root), out, *libraries],
                       env=run_env, check=True, capture_output=True, text=True)
        return {unit: (Path(out) / unit).read_text() for unit in (*libraries, "tlottie")}


def cache_key(stamp: str, rust: str) -> str:
    pinned = RUST_LINE.sub(lambda _: f"rust={rust}", stamp)
    return hashlib.sha256((KEY_SCHEMA + pinned).encode()).hexdigest()


def stamp_file(root: Path, unit: str) -> Path:
    if unit == "tlottie":
        return Path(root) / TLOTTIE_BUILD / ".nanogram-stamp"
    return build_dir(root, unit) / ".framework-stamp"


def build_dir(root: Path, unit: str) -> Path:
    root = Path(root)
    if unit == "tlottie":
        return root / TLOTTIE_BUILD
    projects = root / "core-xprojects"
    if projects.is_dir():
        for name in sorted(os.listdir(projects)):
            if name.lower() == unit.lower():
                return projects / name / "build"
    return projects / unit / "build"


def header_pairs(root: Path) -> list[tuple[Path, Path]]:
    text = (frameworks.SCRIPTS / "configure_frameworks.sh").read_text()
    pairs = [(Path(root) / source, Path(root) / dest) for source, dest in PAIR.findall(text)]
    if not pairs or TD_PAIR[1] not in text:
        raise config.ConfigError("scripts/configure_frameworks.sh changed its header sync: update fwcache.py")
    return pairs + [(Path(root) / TD_PAIR[0], Path(root) / TD_PAIR[1])]


def header_sources(root: Path) -> list[Path]:
    sources: list[Path] = []
    for source, _ in header_pairs(root):
        if source not in sources:
            sources.append(source)
    return sources


def required_outputs_by_unit(root: Path) -> dict[str, list[Path]]:
    root = Path(root)
    libraries = frameworks.libraries()
    out = subprocess.run(["bash", "-c", OUTPUTS_SCRIPT, "bash", str(frameworks.SCRIPTS), str(root), *libraries],
                         capture_output=True, text=True, check=True).stdout
    outputs: dict[str, list[Path]] = {unit: [] for unit in UNITS}
    for line in out.splitlines():
        unit, _, path = line.partition("\t")
        if path:
            outputs[unit].append(Path(path))
    outputs["tlottie"] = [root / TLOTTIE_LIBRARY]
    return outputs


def _folded(path: Path) -> tuple[str, ...]:
    return tuple(part.casefold() for part in path.parts)


def _is_within(path: Path, parent: Path) -> bool:
    inner, outer = _folded(path), _folded(parent)
    return inner[:len(outer)] == outer


def _files_below(top: Path) -> list[Path]:
    found = []
    for directory, _, names in os.walk(top):
        found.extend(Path(directory) / name for name in names)
    return found


def _include_tree(path: Path, build: Path) -> Path | None:
    outermost = None
    for parent in path.parents:
        if not _is_within(parent, build) or len(parent.parts) <= len(build.parts):
            break
        if parent.name == "include":
            outermost = parent
    return outermost


def _synced_headers(build: Path, sources: list[Path]) -> list[Path]:
    prefixes = [_folded(s)[len(build.parts):] for s in sources if _is_within(s, build)]
    if not prefixes or not build.is_dir():
        return []
    found = []
    for directory, dirnames, names in os.walk(build):
        rel = _folded(Path(directory))[len(build.parts):]
        inside = any(rel[:len(p)] == p for p in prefixes)
        dirnames[:] = [d for d in dirnames
                       if inside or any(p[:len(rel) + 1] == rel + (d.casefold(),) for p in prefixes)]
        if inside:
            found.extend(Path(directory) / n for n in names if n.endswith(".h"))
    return found


def cached_files(root: Path, unit: str, outputs: Mapping[str, list[Path]] | None = None) -> list[Path]:
    root = Path(root)
    build = build_dir(root, unit)
    required = (outputs or required_outputs_by_unit(root))[unit]
    files: set[Path] = {p for p in required if p.is_file()}
    for path in required:
        if path.suffix == ".h":
            tree = _include_tree(path, build)
            if tree is not None and tree.is_dir():
                files.update(_files_below(tree))
    files.update(_synced_headers(build, header_sources(root)))
    if unit in EXTRA_OUTPUTS and (root / EXTRA_OUTPUTS[unit]).is_dir():
        files.update(_files_below(root / EXTRA_OUTPUTS[unit]))
    return sorted(p.relative_to(root) for p in files if p.is_file())


@dataclass(frozen=True)
class Entry:
    key: str
    unit: str
    path: Path
    size: int
    last_used: float


def cache_root() -> Path:
    return Path(config.CACHE_DIR) / "frameworks"


def max_bytes() -> int:
    return int(float(os.environ.get("NANOGRAM_FRAMEWORK_CACHE_MAX_GB", DEFAULT_MAX_GB)) * 1024**3)


@contextlib.contextmanager
def cache_lock(mode: int) -> Iterator[None]:
    root = cache_root()
    root.mkdir(parents=True, exist_ok=True)
    with open(root / ".lock", "a") as handle:
        fcntl.flock(handle, mode)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def _entry(path: Path) -> Entry | None:
    meta_path = path / "meta.json"
    try:
        meta = json.loads(meta_path.read_text())
        return Entry(meta["key"], meta["unit"], path, int(meta["size"]), meta_path.stat().st_mtime)
    except (OSError, ValueError, KeyError):
        return None


def lookup(key: str) -> Entry | None:
    return _entry(cache_root() / key)


def _clone(sources: list[Path], destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for start in range(0, len(sources), COPY_CHUNK):
        chunk = [str(p) for p in sources[start:start + COPY_CHUNK]]
        if subprocess.run(["cp", "-c", "-p", *chunk, str(destination)], capture_output=True).returncode != 0:
            subprocess.run(["cp", "-p", *chunk, str(destination)], check=True, capture_output=True)


def _clone_tree(source: Path, parent: Path) -> None:
    parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-c", "-R", "-p", str(source), str(parent)], capture_output=True).returncode != 0:
        subprocess.run(["cp", "-R", "-p", str(source), str(parent)], check=True, capture_output=True)


def store(root: Path, unit: str, key: str, stamp: str) -> Entry:
    root = Path(root)
    with cache_lock(fcntl.LOCK_EX):
        existing = lookup(key)
        if existing is not None:
            return existing
        final = cache_root() / key
        partial = cache_root() / f"{key}.partial-{os.getpid()}"
        shutil.rmtree(partial, ignore_errors=True)
        shutil.rmtree(final, ignore_errors=True)
        files = cached_files(root, unit)
        if not files:
            raise config.ConfigError(f"{unit} has no outputs to cache in {root}")
        by_dir: dict[Path, list[Path]] = {}
        for rel in files:
            by_dir.setdefault(rel.parent, []).append(root / rel)
        for rel_dir, sources in sorted(by_dir.items()):
            _clone(sources, partial / "tree" / rel_dir)
        size = sum((root / rel).stat().st_size for rel in files)
        meta = {"schema": META_SCHEMA, "unit": unit, "key": key, "stamp": stamp, "created": time.time(), "size": size}
        (partial / "meta.json").write_text(json.dumps(meta, indent=1) + "\n")
        os.rename(partial, final)
        entry = lookup(key)
        assert entry is not None
        return entry


def _remove_outputs(root: Path, unit: str) -> None:
    shutil.rmtree(build_dir(root, unit), ignore_errors=True)
    if unit in EXTRA_OUTPUTS:
        shutil.rmtree(Path(root) / EXTRA_OUTPUTS[unit], ignore_errors=True)


def restore(root: Path, unit: str, entry: Entry, local_stamp: str) -> None:
    root = Path(root)
    with cache_lock(fcntl.LOCK_SH):
        tree = entry.path / "tree"
        if not tree.is_dir():
            raise config.ConfigError(f"cache entry {entry.path} has no files; run tg frameworks --no-cache")
        _remove_outputs(root, unit)
        for top in sorted(tree.iterdir()):
            _clone_tree(top, root)
        stamp = stamp_file(root, unit)
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(local_stamp)
        os.utime(entry.path / "meta.json")


def entries() -> list[Entry]:
    root = cache_root()
    if not root.is_dir():
        return []
    found = [_entry(path) for path in root.iterdir() if path.is_dir() and ".partial-" not in path.name]
    return sorted((e for e in found if e is not None), key=lambda e: e.last_used)


def cache_size() -> int:
    return sum(e.size for e in entries())


def prune(limit: int, keep: set[str]) -> list[Entry]:
    root = cache_root()
    if not root.is_dir():
        return []
    evicted: list[Entry] = []
    with cache_lock(fcntl.LOCK_EX):
        now = time.time()
        for path in root.iterdir():
            if not path.is_dir():
                continue
            if ".partial-" in path.name:
                if now - path.stat().st_mtime > PARTIAL_MAX_AGE:
                    shutil.rmtree(path, ignore_errors=True)
            elif _entry(path) is None:
                shutil.rmtree(path, ignore_errors=True)
        current = entries()
        total = sum(e.size for e in current)
        for entry in current:
            if total <= limit:
                break
            if entry.key in keep:
                continue
            shutil.rmtree(entry.path, ignore_errors=True)
            total -= entry.size
            evicted.append(entry)
    return evicted
