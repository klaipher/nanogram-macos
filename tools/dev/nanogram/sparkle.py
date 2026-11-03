"""Sparkle EdDSA (ed25519) keys and update signatures for the direct edition.

We use Sparkle's own vendored ed25519 code (Sparkle 2: Vendor/ed25519-sparkle, the same upstream commit
Sparkle 1.21 vendored) through a small helper (sparkle_ed25519.c) built into ~/.cache/nanogram-macos, so no
Keychain is involved. The private key is a 32-byte RFC 8032 seed, stored base64 in
~/.config/nanogram-macos/sparkle_ed25519 (dir 0700, file 0600) — the format Sparkle 2's
`sign_update --ed-key-file` reads. Secrets reach the helper on stdin only and are
never printed: the CLI prints the public key and appcast signatures.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import os
import secrets
import stat
import subprocess
import sys
from pathlib import Path

from nanogram import config

KEY_FILE = config.mac_config() / "sparkle_ed25519"
FEED_URL = "https://github.com/klaipher/nanogram-releases/releases/latest/download/appcast.xml"
HELPER_SOURCE = Path(__file__).with_name("sparkle_ed25519.c")
ED25519_DIR = config.ROOT / "submodules" / "Sparkle" / "Vendor" / "ed25519-sparkle" / "src"
ED25519_SOURCES = ("fe.c", "ge.c", "keypair.c", "sc.c", "sha512.c", "sign.c", "verify.c")

__all__ = ["KEY_FILE", "FEED_URL", "SparkleError", "ensure_keys", "public_key", "sign", "verify"]


class SparkleError(config.ConfigError):
    pass


def _helper() -> Path:
    sources = [HELPER_SOURCE] + [ED25519_DIR / name for name in ED25519_SOURCES]
    missing = [str(s) for s in sources if not s.is_file()]
    if missing:
        raise SparkleError(f"missing {missing[0]}: run tools/dev/tg setup (Sparkle submodule)")
    digest = hashlib.sha256(b"".join(s.read_bytes() for s in sources)).hexdigest()[:16]
    binary = config.CACHE_DIR / "sparkle-ed25519" / digest / "sparkle_ed25519"
    if binary.is_file():
        return binary
    binary.parent.mkdir(parents=True, exist_ok=True)
    tmp = binary.with_suffix(f".tmp{os.getpid()}")
    build = subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Werror", "-I", str(ED25519_DIR), "-o", str(tmp)]
                           + [str(s) for s in sources], capture_output=True, text=True)
    if build.returncode != 0:
        raise SparkleError(f"cannot build the ed25519 helper: {build.stderr.strip().splitlines()[-1:]}")
    os.replace(tmp, binary)
    return binary


def _run(args: list[str], stdin: bytes) -> subprocess.CompletedProcess:
    return subprocess.run([str(_helper())] + args, input=stdin, capture_output=True)


def _check_private(path: Path, mode: int, what: str) -> None:
    actual = stat.S_IMODE(path.stat().st_mode)
    if actual != mode:
        raise SparkleError(f"{path}: {what} must be mode {mode:04o} (is {actual:04o}); fix with chmod {mode:o} {path}")


def _read_seed(key_file: Path) -> bytes:
    if not key_file.is_file():
        raise SparkleError(f"no Sparkle key at {key_file}: run tools/dev/tg sparkle-key")
    _check_private(key_file.parent, 0o700, "the key folder")
    _check_private(key_file, 0o600, "the private key")
    try:
        seed = base64.b64decode(key_file.read_text().strip(), validate=True)
    except (binascii.Error, ValueError):
        seed = b""
    if len(seed) != 32:
        raise SparkleError(f"{key_file}: expected a base64 32-byte ed25519 seed (value not shown)")
    return seed


def _create(key_file: Path) -> None:
    key_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(key_file.parent, 0o700)
    fd = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(base64.b64encode(secrets.token_bytes(32)).decode() + "\n")


def public_key(key_file: Path = KEY_FILE) -> str:
    result = _run(["public"], _read_seed(Path(key_file)))
    if result.returncode != 0 or len(result.stdout) != 32:
        raise SparkleError("the ed25519 helper could not derive the public key")
    return base64.b64encode(result.stdout).decode()


def ensure_keys(key_file: Path = KEY_FILE) -> str:
    """Creates the private key once (never overwrites it) and returns the base64 public key (SUPublicEDKey)."""
    key_file = Path(key_file)
    if not key_file.exists():
        _create(key_file)
    return public_key(key_file)


def sign(archive: Path, key_file: Path = KEY_FILE) -> str:
    """The base64 sparkle:edSignature of `archive`."""
    seed = _read_seed(Path(key_file))
    result = _run(["sign", str(archive)], seed)
    if result.returncode != 0 or len(result.stdout) != 64:
        raise SparkleError(f"cannot sign {archive}: {result.stderr.decode().strip()}")
    return base64.b64encode(result.stdout).decode()


def verify(archive: Path, signature: str, public: str) -> bool:
    try:
        stdin = base64.b64decode(public, validate=True) + base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError):
        return False
    if len(stdin) != 96:
        return False
    result = _run(["verify", str(archive)], stdin)
    if result.returncode not in (0, 1):
        raise SparkleError(f"cannot verify {archive}: {result.stderr.decode().strip()}")
    return result.returncode == 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tg sparkle-key")
    parser.add_argument("--key-file", type=Path, default=KEY_FILE)
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("public-key", help="create the key once, print the public key (SUPublicEDKey)")
    signing = commands.add_parser("sign", help="print the appcast enclosure attributes of an archive")
    signing.add_argument("archive", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "sign":
            signature = sign(args.archive, args.key_file)
            print(f'sparkle:edSignature="{signature}" length="{args.archive.stat().st_size}"')
        else:
            created = not args.key_file.exists()
            public = ensure_keys(args.key_file)
            if created:
                print(f"sparkle: created the private key {args.key_file} (0600, never commit or print it)", file=sys.stderr)
            print(public)
    except config.ConfigError as error:
        print(f"sparkle: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
