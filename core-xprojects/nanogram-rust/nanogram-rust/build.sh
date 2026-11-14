#!/bin/sh

set -e
set -x

SOURCE_DIR="$1"
BUILD_DIR="$2"
PACKAGE_DIR="$3"

if [ -z "$SOURCE_DIR" ] || [ -z "$BUILD_DIR" ] || [ -z "$PACKAGE_DIR" ]; then
    echo "Usage: $0 SOURCE_DIR BUILD_DIR PACKAGE_DIR"
    echo "Example: $0 /path/to/third-party/nanogram-rust /path/to/build /path/to/packages/RustLibraries"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -f "$SOURCE_DIR/Cargo.toml" ]; then
    echo "nanogram-rust sources are missing at $SOURCE_DIR"
    echo "Check out the telegram-ios submodule first:"
    echo "  git submodule update --init --recursive submodules/telegram-ios"
    exit 1
fi

mkdir -p "$BUILD_DIR" "$PACKAGE_DIR"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"

# wallet-engine and mtproto-engine stage their headers; their units are built first.
WALLET_HEADERS="$PROJECTS_DIR/wallet-engine/build/headers"
MTPROTO_HEADERS="$PROJECTS_DIR/mtproto-engine/build/headers"
for HEADER in "$WALLET_HEADERS/wallet_engineFFI.h" "$WALLET_HEADERS/module.modulemap" "$MTPROTO_HEADERS/mtproto_engine.h"; do
    if [ ! -s "$HEADER" ]; then
        echo "$HEADER is missing: build the wallet-engine and mtproto-engine units first"
        exit 1
    fi
done

if [ -n "${CARGO:-}" ]; then
    CARGO_BIN="$CARGO"
elif command -v cargo >/dev/null 2>&1; then
    CARGO_BIN="$(command -v cargo)"
elif [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO_BIN="$HOME/.cargo/bin/cargo"
else
    echo "cargo was not found. Install the toolchain with:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal"
    exit 1
fi

RUSTUP_BIN="$(dirname "$CARGO_BIN")/rustup"

NANOGRAM_RUST_TOOLCHAIN_FILE="$PROJECTS_DIR/rust-toolchain.toml"
RUSTUP_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$NANOGRAM_RUST_TOOLCHAIN_FILE")"
if [ -z "$RUSTUP_TOOLCHAIN" ]; then
    echo "no Rust channel in $NANOGRAM_RUST_TOOLCHAIN_FILE"
    exit 1
fi
export RUSTUP_TOOLCHAIN

if [ -x "$RUSTUP_BIN" ] && ! "$RUSTUP_BIN" run "$RUSTUP_TOOLCHAIN" rustc --version >/dev/null 2>&1; then
    "$RUSTUP_BIN" toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal >/dev/null 2>&1
fi

cd "$SOURCE_DIR"

for RUST_TARGET in aarch64-apple-darwin; do
    if [ -x "$RUSTUP_BIN" ]; then
        "$RUSTUP_BIN" target add "$RUST_TARGET" >/dev/null 2>&1 || true
    fi
    # One staticlib for tlottie, mtproto-engine and wallet-engine: three fat-LTO archives each carry their own copy of
    # std and the linker reports a duplicate rust_eh_personality. staticlib only, so Cargo runs the LTO.
    env -u MACOSX_DEPLOYMENT_TARGET CARGO_TARGET_DIR="$BUILD_DIR/lib" "$CARGO_BIN" rustc \
        --lib \
        --crate-type staticlib \
        --release \
        --locked \
        --target "$RUST_TARGET"
done

cp "$BUILD_DIR/lib/aarch64-apple-darwin/release/libnanogram_rust.a" "$BUILD_DIR/libnanogram_rust.a"

HEADERS_DIR="$BUILD_DIR/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$WALLET_HEADERS/wallet_engineFFI.h" "$MTPROTO_HEADERS/mtproto_engine.h" "$HEADERS_DIR/"
{
    cat "$WALLET_HEADERS/module.modulemap"
    cat <<MAP

module MTProtoEngineFFI {
    header "mtproto_engine.h"
    export *
}
MAP
} > "$HEADERS_DIR/module.modulemap"

rm -rf "$PACKAGE_DIR/NanogramRustFFI.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/libnanogram_rust.a" \
    -headers "$HEADERS_DIR" \
    -output "$PACKAGE_DIR/NanogramRustFFI.xcframework"

lipo -info "$BUILD_DIR/libnanogram_rust.a"
echo "nanogram-rust artifacts updated in $PACKAGE_DIR"
