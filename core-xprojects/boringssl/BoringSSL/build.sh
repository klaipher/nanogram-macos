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

# The one BoringSSL iOS and Android also build (klaipher/boringssl, branch nanogram), from the core's submodule.
CORE_SSL_DIR="${SCRIPT_LOCATION}/../../../submodules/telegram-ios/third-party/boringssl/src"
if [ ! -f "$CORE_SSL_DIR/CMakeLists.txt" ]; then
  echo "error: $CORE_SSL_DIR is empty" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi

SDKROOT="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

# The hardening flags .bazelrc applies to every C-family compile on iOS.
HARDENING_FLAGS="-ftrivial-auto-var-init=zero -fstack-protector-strong -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"

for ARCH in ${ARCHS:-arm64}
do
  mkdir -p "$OUT_DIR/$ARCH"

  # The assembly stays on, as on iOS.
  cmake -G Ninja \
    -S "$CORE_SSL_DIR" \
    -B "$OUT_DIR/$ARCH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0} \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_C_FLAGS="$HARDENING_FLAGS" \
    -DCMAKE_CXX_FLAGS="$HARDENING_FLAGS" \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG"

  ninja -C "$OUT_DIR/$ARCH" crypto ssl

  CRYPTO_LIST+=" $OUT_DIR/$ARCH/libcrypto.a"
  SSL_LIST+=" $OUT_DIR/$ARCH/libssl.a"
done

mkdir -p ${OUT_DIR}/boringssl/lib
mkdir -p ${OUT_DIR}/boringssl/include

cp -a "$CORE_SSL_DIR/include/openssl" ${OUT_DIR}/boringssl/include/
lipo -create ${CRYPTO_LIST} -output ${OUT_DIR}/boringssl/lib/libcrypto.a
lipo -create ${SSL_LIST} -output ${OUT_DIR}/boringssl/lib/libssl.a
