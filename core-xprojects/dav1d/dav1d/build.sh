#!/bin/sh

set -e

SOURCE_DIR="$1"
BUILD_DIR="$2"

if [ -z "$SOURCE_DIR" ] || [ -z "$BUILD_DIR" ]; then
    echo "Usage: $0 SOURCE_DIR BUILD_DIR"
    echo "Example: $0 /path/to/dav1d/source /path/to/build/directory"
    exit 1
fi

MESON_OPTIONS="--buildtype=release --default-library=static -Denable_tools=false -Denable_tests=false"

# Ensure build directory exists
mkdir -p "$BUILD_DIR"

# Build for ARM64
echo "Building for arm64..."
mkdir -p "$BUILD_DIR/arm64"
pushd "$BUILD_DIR/arm64"

# Cross file from the active toolchain and SDK (xcode-select / DEVELOPER_DIR), not a fixed Xcode path.
CROSS_FILE="$PWD/cross-arm64.meson"
cat > "$CROSS_FILE" <<CROSS
[binaries]
c = ['$(xcrun -f clang)', '-arch', 'arm64', '-isysroot', '$(xcrun --sdk macosx --show-sdk-path)']
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'

[properties]
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSS

meson setup "$SOURCE_DIR" --cross-file="$CROSS_FILE" $MESON_OPTIONS \
    -Dc_args="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" -Dc_link_args="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
ninja
popd

mkdir -p "$BUILD_DIR/dav1d/lib"
cp "$BUILD_DIR/arm64/src/libdav1d.a" "$BUILD_DIR/dav1d/lib/libdav1d.a"

# Copy include files from the source directory
echo "Copying include files from source directory..."
mkdir -p "$BUILD_DIR/dav1d/include"
cp -R "$SOURCE_DIR/include/dav1d" "$BUILD_DIR/dav1d/include/"

echo "Universal library created at $BUILD_DIR/dav1d/lib/libdav1d.a"
echo "Headers copied to $BUILD_DIR/dav1d/include/"
