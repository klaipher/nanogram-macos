"""`tg doctor`: checks every prerequisite and says how to fix what is missing."""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import config

REQUIRED_XCODE_MAJOR = 27
MIN_FREE_GB = 40
SUBMODULE_MARKERS = {
    "rlottie": "submodules/rlottie/CMakeLists.txt",
    "tlottie": "submodules/tlottie/Cargo.toml",
    "telegram-ios": "submodules/telegram-ios/submodules/TelegramCore/Package.swift",
}


@dataclass(frozen=True)
class Finding:
    name: str
    ok: bool
    hint: str
    required: bool = True


def _run_ok(args: list[str]) -> bool:
    try:
        return subprocess.run(args, capture_output=True, check=False).returncode == 0
    except OSError:
        return False


def check_xcode() -> Finding:
    version = config.xcode_version()
    major = version.split(".")[0]
    if major == str(REQUIRED_XCODE_MAJOR):
        return Finding("xcode", True, f"Xcode {version}")
    shown = version or "none"
    return Finding("xcode", False, f"Xcode {REQUIRED_XCODE_MAJOR}.x required, found {shown}: "
                   "install it and run sudo xcode-select -s /Applications/Xcode.app")


def check_metal() -> Finding:
    if _run_ok(["xcrun", "metal", "--version"]):
        return Finding("metal", True, "Metal toolchain installed")
    return Finding("metal", False, "Metal toolchain missing: run xcodebuild -downloadComponent MetalToolchain")


def check_tools() -> Finding:
    missing = [tool for tool in ("cmake", "ninja", "meson") if shutil.which(tool) is None]
    if not missing:
        return Finding("build-tools", True, "cmake, ninja, meson present")
    return Finding("build-tools", False, f"missing {' '.join(missing)}: run brew install {' '.join(missing)}")


def check_rustup() -> Finding:
    if shutil.which("rustup") or (config.RUSTUP_BIN / "rustup").exists():
        return Finding("rustup", True, "rustup present")
    return Finding("rustup", False, "rustup missing: run brew install rustup")


def check_submodules(root: Path | None = None) -> Finding:
    root = root or config.ROOT
    empty = [name for name, marker in SUBMODULE_MARKERS.items() if not (root / marker).is_file()]
    if not empty:
        return Finding("submodules", True, "submodules populated")
    return Finding("submodules", False, f"{', '.join(empty)} not checked out: run git submodule update --init --recursive")


def check_disk(root: Path | None = None) -> Finding:
    free_gb = shutil.disk_usage(root or config.ROOT).free // 10**9
    if free_gb >= MIN_FREE_GB:
        return Finding("disk", True, f"{free_gb} GB free")
    return Finding("disk", False, f"only {free_gb} GB free, a first build needs {MIN_FREE_GB} GB: free some space")


def cache_root_size() -> int:
    from .disk import disk_usage
    return disk_usage(config.CACHE_DIR) if config.CACHE_DIR.is_dir() else 0


def check_caches() -> Finding:
    from .disk import gigabytes, max_total_bytes
    size, cap = cache_root_size(), max_total_bytes(None)
    shown = f"{config.CACHE_DIR} holds {gigabytes(size)} (cap {gigabytes(cap)})"
    if size <= cap:
        return Finding("caches", True, shown, required=False)
    return Finding("caches", False, f"{shown}: run tg prune (tg prune --dry-run lists what goes)", required=False)


def check_api_credentials() -> Finding:
    path = config.api_credentials_path()
    if path.is_file():
        return Finding("api-credentials", True, f"{path} present")
    return Finding("api-credentials", False,
                   f'{path} missing: put {{"api_id": ..., "api_hash": ...}} there (from my.telegram.org/apps)')


def check_asc_key() -> Finding:
    asc = config.asc_dir()
    if (asc / "asc.json").is_file() and any(asc.glob("AuthKey_*.p8")):
        return Finding("asc-key", True, "App Store Connect key present", required=False)
    return Finding("asc-key", False, f"no App Store Connect key in {asc} (asc.json + AuthKey_<id>.p8): "
                   "needed only for tg testflight / release-direct", required=False)


def _identities() -> str:
    try:
        return subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                              capture_output=True, text=True, check=False).stdout
    except OSError:
        return ""


def check_identities() -> list[Finding]:
    found = _identities()
    findings = []
    for name, label, purpose in (("developer-id", "Developer ID Application", "tg release-direct"),
                                 ("apple-distribution", "Apple Distribution", "tg testflight")):
        if f'"{label}:' in found:
            findings.append(Finding(name, True, f"{label} identity present", required=False))
        else:
            findings.append(Finding(name, False, f"no {label} identity in the keychain: "
                                    f"needed only for {purpose} (Xcode > Settings > Accounts > Manage Certificates)",
                                    required=False))
    return findings


def run_doctor() -> list[Finding]:
    return [
        check_xcode(),
        check_metal(),
        check_tools(),
        check_rustup(),
        check_submodules(),
        check_disk(),
        check_caches(),
        check_api_credentials(),
        check_asc_key(),
        *check_identities(),
    ]


def main() -> int:
    findings = run_doctor()
    for f in findings:
        mark = "ok  " if f.ok else ("FAIL" if f.required else "warn")
        print(f"{mark} {f.name:<20} {f.hint}")
    return 1 if any(f.required and not f.ok for f in findings) else 0


if __name__ == "__main__":
    raise SystemExit(main())
