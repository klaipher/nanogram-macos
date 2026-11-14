#/bin/sh

set -x
set -e

# The WebRTC tree is klaipher/webrtc (branch nanogram, submodules/webrtc), the one source iOS, Mac and Android pin.
# It carries the tg_owt CMake build at its root; third-party sources come from the single sources:
#   libyuv from the iOS core's klaipher/libyuv submodule (TG_OWT_LIBYUV_DIR),
#   abseil, libsrtp and crc32c from the fork's own submodules (third_party/).
SOURCE_DIR="$1"

OPENSSL_DIR="$2"
JPEG_DIR="$3"
OPUS_DIR="$4"
FFMPEG_DIR="$5"
LIBVPX_DIR="$6"
OPENH264_DIR="$7"
LIBYUV_DIR="$8"

if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ] || [ ! -f "$SOURCE_DIR/third_party/abseil-cpp/absl/base/attributes.h" ] || [ ! -f "$SOURCE_DIR/third_party/libsrtp/include/srtp.h" ]; then
    echo "error: $SOURCE_DIR is empty or has empty submodules; run 'git submodule update --init --recursive'" >&2
    exit 1
fi
if [ ! -f "$LIBYUV_DIR/include/libyuv.h" ]; then
    echo "error: $LIBYUV_DIR is empty; run 'git -C submodules/telegram-ios submodule update --init third-party/libyuv/third_party/libyuv'" >&2
    exit 1
fi
LIBYUV_DIR="$(cd "$LIBYUV_DIR" && pwd -P)"

BUILD_DIR="${PROJECT_DIR}/build/"
SRC_DIR="${BUILD_DIR}src"

rm -rf $BUILD_DIR || true
mkdir -p $SRC_DIR || true

# build/src is the header root that scripts/configure_frameworks.sh syncs into tgcalls/SharedHeaders/webrtc.
rsync -a --exclude .git "$SOURCE_DIR/" "$SRC_DIR/"

# Apple Clang rejects ABSL_ATTRIBUTE_LIFETIME_BOUND on parameters of void-returning functions. The fork's guarded
# workaround copies pristine abseil and disables the macro there (annotation only, no runtime or ABI effect); the
# patched copy is what both this build and the tgcalls headers see. NANOGRAM_ABSEIL_WORKAROUND=0 skips it to find out
# whether the pristine abseil builds.
if [ "${NANOGRAM_ABSEIL_WORKAROUND:-1}" != "0" ]; then
    sh "$SRC_DIR/nanogram/apply_abseil_workaround.sh" "$SOURCE_DIR/third_party/abseil-cpp" "$SRC_DIR/third_party/abseil-cpp"
fi

# tgcalls includes <third_party/libyuv/include/...> through SharedHeaders/webrtc: provide the single libyuv's headers there.
mkdir -p "$SRC_DIR/third_party/libyuv/include"
rsync -rl --include='*/' --include='*.h' --exclude='*' "$LIBYUV_DIR/include/" "$SRC_DIR/third_party/libyuv/include/"

LIBS=""
for ARCH in $ARCHS
do

CURRENT_ARCH=$ARCH
OUT_DIR=$CURRENT_ARCH
mkdir -p ${BUILD_DIR}${OUT_DIR} || true

cmake -G Ninja \
    -S "$SRC_DIR" \
    -B "${BUILD_DIR}${OUT_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES=$CURRENT_ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DTG_OWT_SPECIAL_TARGET=macstore \
    -DCMAKE_BUILD_TYPE=Release \
    -DNDEBUG=1 \
    -DTG_OWT_BUILD_AUDIO_BACKENDS=ON \
    -DTG_OWT_LIBJPEG_INCLUDE_PATH=$JPEG_DIR \
    -DTG_OWT_OPENSSL_INCLUDE_PATH=$OPENSSL_DIR \
    -DTG_OWT_OPUS_INCLUDE_PATH=$OPUS_DIR \
    -DTG_OWT_LIBVPX_INCLUDE_PATH=$LIBVPX_DIR \
    -DTG_OWT_OPENH264_INCLUDE_PATH=$OPENH264_DIR \
    -DTG_OWT_FFMPEG_INCLUDE_PATH=$FFMPEG_DIR \
    -DTG_OWT_LIBYUV_DIR=$LIBYUV_DIR
    # -DCMAKE_BUILD_TYPE=Debug

ninja -C "${BUILD_DIR}${OUT_DIR}"
LIBS="$LIBS ${BUILD_DIR}$OUT_DIR/libtg_owt.a"

done
#
LIB_PATH=${BUILD_DIR}webrtc
rm -rf $LIB_PATH || true
mkdir -p $LIB_PATH
lipo -create $LIBS -output "$LIB_PATH/libmac_framework_objc_static.a" || exit 1
