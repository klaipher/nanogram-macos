set -e
set -x

# Resolve before any cd, $0 can be relative.
SCRIPT_LOCATION="$(cd "$(dirname "$0")" && pwd -P)"

BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")

cd $BUILD_DIR

rm -rf build || true
mkdir build

OUT_DIR="${BUILD_DIR}build"
mkdir -p $OUT_DIR

# libopus v1.6.1 from the core's xiph/opus submodule (the one source iOS and Android also build).
CORE_OPUS_DIR="${SCRIPT_LOCATION}/../../../submodules/telegram-ios/third-party/opus/opus"
if [ ! -f "$CORE_OPUS_DIR/CMakeLists.txt" ]; then
  echo "error: $CORE_OPUS_DIR is empty" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

SOURCE_DIR="$OUT_DIR/opus-1.6.1"
mkdir -p "$SOURCE_DIR"
rsync -a --exclude .git "$CORE_OPUS_DIR/" "$SOURCE_DIR/"
# The release tarball ships package_version; a git checkout would ask git, which has no repository in the copy.
echo 'PACKAGE_VERSION="1.6.1"' > "$SOURCE_DIR/package_version"

SDKROOT="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

# The same options as third-party/opus/build-opus-bazel.sh in the core (checked by tools/dev/native/check_native_libs.py).
COMMON_ARGS="-DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DBUILD_TESTING=OFF -DOPUS_DISABLE_INTRINSICS=OFF -DOPUS_FIXED_POINT=OFF -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"

for ARCH in $ARCHS
do
  mkdir -p "$OUT_DIR/$ARCH"

  cmake -G Ninja \
    -S "$SOURCE_DIR" \
    -B "$OUT_DIR/$ARCH" \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    $COMMON_ARGS \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG"

  ninja -C "$OUT_DIR/$ARCH"

  LIBLIST+=" $OUT_DIR/$ARCH/libopus.a"
done

mkdir -p ${OUT_DIR}/libopus/lib
mkdir -p ${OUT_DIR}/libopus/include/opus

cp -a ${SOURCE_DIR}/include/ ${OUT_DIR}/libopus/include/opus
lipo -create ${LIBLIST} -output ${OUT_DIR}/libopus/lib/libopus.a
