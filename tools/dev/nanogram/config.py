"""Paths and environment checks shared by every tg command."""
from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HOME = Path.home()
CACHE_DIR = Path(os.environ.get("NANOGRAM_CACHE_DIR", HOME / ".cache" / "nanogram-macos"))
COMPILATION_CACHE = CACHE_DIR / "CompilationCache"
CHECKOUT_PREFIX = "nanogram-macos"


def derived_data_dir(root: Path, cache_dir: Path, env: Mapping[str, str]) -> Path:
    if env.get("NANOGRAM_DERIVED_DATA"):
        return Path(env["NANOGRAM_DERIVED_DATA"])
    suffix = Path(root).name.removeprefix(CHECKOUT_PREFIX).lstrip("-")
    return Path(cache_dir) / (f"DerivedData-{suffix}" if suffix else "DerivedData")


DERIVED_DATA = derived_data_dir(ROOT, CACHE_DIR, os.environ)
TG_IOS_CONFIG = HOME / ".config" / "telegram-ios"
MAC_CONFIG = HOME / ".config" / "nanogram-macos"
BUILD_OUTPUT = ROOT / "build-output"
RUSTUP_BIN = Path("/opt/homebrew/opt/rustup/bin")


class ConfigError(Exception):
    """A missing or wrong prerequisite, carrying one actionable line."""

    def __init__(self, message: str):
        super().__init__(" ".join(message.split()))


def tg_ios_config() -> Path:
    return Path(os.environ.get("TG_IOS_CONFIG", TG_IOS_CONFIG))


def mac_config() -> Path:
    return Path(os.environ.get("NANOGRAM_MAC_CONFIG", MAC_CONFIG))


def api_credentials_path() -> Path:
    return tg_ios_config() / "api-credentials.json"


def dsym_dir() -> Path:
    return Path(os.environ.get("NANOGRAM_DSYM_DIR", HOME / "Library" / "Application Support" / "Nanogram" / "dsyms" / "mac"))


def asc_dir() -> Path:
    return tg_ios_config() / "asc"


def xcode_version() -> str:
    """Version of the selected Xcode, e.g. "27.2"; empty if xcodebuild is unusable."""
    try:
        out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""
    first = out.splitlines()[0] if out else ""
    parts = first.split()
    return parts[1] if len(parts) >= 2 and parts[0] == "Xcode" else ""


def require_file(path: Path, hint: str) -> Path:
    if not Path(path).is_file():
        raise ConfigError(f"{path} is missing: {hint}")
    return Path(path)
