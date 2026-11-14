#!/bin/sh

set -e
set -x

SOURCE_DIR="$1"
BUILD_DIR="$2"
PACKAGE_DIR="$3"

if [ -z "$SOURCE_DIR" ] || [ -z "$BUILD_DIR" ] || [ -z "$PACKAGE_DIR" ]; then
    echo "Usage: $0 SOURCE_DIR BUILD_DIR PACKAGE_DIR"
    echo "Example: $0 /path/to/third-party/mtproto-engine /path/to/build /path/to/submodules/MTProtoRustEngine"
    exit 1
fi

if [ ! -f "$SOURCE_DIR/Cargo.toml" ]; then
    echo "mtproto-engine sources are missing at $SOURCE_DIR"
    echo "Check out the telegram-ios submodule first:"
    echo "  git submodule update --init submodules/telegram-ios"
    exit 1
fi

mkdir -p "$BUILD_DIR" "$PACKAGE_DIR"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"

if [ -n "${CARGO:-}" ]; then
    CARGO_BIN="$CARGO"
elif command -v cargo >/dev/null 2>&1; then
    CARGO_BIN="$(command -v cargo)"
elif [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO_BIN="$HOME/.cargo/bin/cargo"
else
    echo "cargo was not found. mtproto-engine is a Rust library; install the toolchain pinned in"
    echo "$SOURCE_DIR/rust-toolchain.toml with:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal"
    echo "then re-run this script (rustup installs the pinned toolchain automatically)."
    exit 1
fi

RUSTUP_BIN="$(dirname "$CARGO_BIN")/rustup"

NANOGRAM_RUST_TOOLCHAIN_FILE="$(cd "$(dirname "$0")/../.." && pwd)/rust-toolchain.toml"
RUSTUP_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$NANOGRAM_RUST_TOOLCHAIN_FILE")"
if [ -z "$RUSTUP_TOOLCHAIN" ]; then
    echo "no Rust channel in $NANOGRAM_RUST_TOOLCHAIN_FILE"
    exit 1
fi
export RUSTUP_TOOLCHAIN

if [ -x "$RUSTUP_BIN" ] && ! "$RUSTUP_BIN" run "$RUSTUP_TOOLCHAIN" rustc --version >/dev/null 2>&1; then
    "$RUSTUP_BIN" toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal >/dev/null 2>&1
fi

mkdir -p "$BUILD_DIR"

cd "$SOURCE_DIR"

# The staticlib is built by nanogram-rust together with tlottie and wallet-engine; this unit only stages the header.
HEADERS_DIR="$BUILD_DIR/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$SOURCE_DIR/crates/mtproto-ffi/include/mtproto_engine.h" "$HEADERS_DIR/"
echo "mtproto-engine header staged in $HEADERS_DIR"
