#!/bin/sh

set -e
set -x

SOURCE_DIR="$1"
BUILD_DIR="$2"
BORINGSSL_DIR="$3"

if [ -z "$SOURCE_DIR" ] || [ -z "$BUILD_DIR" ] || [ -z "$BORINGSSL_DIR" ]; then
    echo "Usage: $0 SOURCE_DIR BUILD_DIR BORINGSSL_DIR"
    echo "Example: $0 /path/to/td /path/to/build /path/to/boringssl"
    exit 1
fi

boringssl_crypto_library="${BORINGSSL_DIR}/lib/libcrypto.a"
options=""
options="$options -DOPENSSL_FOUND=1"
#options="$options -DOPENSSL_CRYPTO_LIBRARY=${boringssl_crypto_library}"
options="$options -DOPENSSL_INCLUDE_DIR=${BORINGSSL_DIR}/include"
options="$options -DCMAKE_BUILD_TYPE=Release"

# Step 1: Generate TDLib source files once
GEN_DIR="$BUILD_DIR/native-gen"
mkdir -p "$GEN_DIR"
pushd "$GEN_DIR"
cmake -G Ninja -DTD_GENERATE_SOURCE_FILES=ON "$SOURCE_DIR"
cmake --build . --parallel
popd

# Step 2: Build for arm64
echo "Building for arm64..."
ARM64_DIR="$BUILD_DIR/arm64"
mkdir -p "$ARM64_DIR"
pushd "$ARM64_DIR"

# tde2e checks the conference-call blockchain and encrypts and decrypts call frames from other
# participants, so the library gets the memory-safety hardening Nanogram.xcconfig gives the app's own
# C, C++ and Objective-C (this CMake build does not see those settings). Only this target build: the
# TL source generators above run on the build machine and stay plain.
HARDENING_FLAGS="-ftrivial-auto-var-init=zero -fstack-protector-strong -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"

cmake -G Ninja "$SOURCE_DIR" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_C_FLAGS="$HARDENING_FLAGS" \
    -DCMAKE_CXX_FLAGS="$HARDENING_FLAGS" \
    $options

cmake --build . --target tde2e --parallel
popd

OUTPUT_DIR="$BUILD_DIR/tde2e"
mkdir -p "$OUTPUT_DIR/lib"
cp "$ARM64_DIR/tde2e/libtde2e.a" "$OUTPUT_DIR/lib/libtde2e.a"
cp "$ARM64_DIR/tdutils/libtdutils.a" "$OUTPUT_DIR/lib/libtdutils.a"
