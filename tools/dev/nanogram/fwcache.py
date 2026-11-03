"""Content-addressed cache of the native libraries, shared by every checkout of this repository.

An entry is keyed by upstream's framework stamp (inputs, Xcode, deployment target, architectures, dependency
stamps) with the `rust=` line pinned to the toolchain the Rust libraries are really built with. It holds only
what the app build and dependent library builds read; restoring clones the files (APFS) into the checkout and
writes the checkout's own stamp so scripts/configure_frameworks.sh skips the library.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from collections.abc import Mapping
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
PAIR_SOURCE = re.compile(r'^\s*"\$\{SCRIPT_DIR\}/\.\./([^,"]+),', re.MULTILINE)

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


def header_sources(root: Path) -> list[Path]:
    text = (frameworks.SCRIPTS / "configure_frameworks.sh").read_text()
    sources: list[Path] = []
    for rel in PAIR_SOURCE.findall(text):
        path = Path(root) / rel
        if path not in sources:
            sources.append(path)
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
