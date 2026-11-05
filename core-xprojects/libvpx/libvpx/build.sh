
set -e
set -x

# Resolve before any cd, $0 can be relative.
SCRIPT_LOCATION="$(cd "$(dirname "$0")" && pwd -P)"


SRC_DIR="$1"
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")



# libvpx is built from the core's libvpx submodule (one copy for iOS and Mac).
# The source is copied into the build directory below; nothing is written into the submodule.
SOURCE_DIR="$(cd "${SCRIPT_LOCATION}/../../../submodules/telegram-ios/third-party/libvpx/libvpx" 2>/dev/null && pwd -P)" || SOURCE_DIR=""
if [ -z "$SOURCE_DIR" ] || [ ! -f "$SOURCE_DIR/configure" ]; then
  echo "error: libvpx source not found in submodules/telegram-ios/third-party/libvpx/libvpx" >&2
  echo "       run: git submodule update --init --recursive" >&2
  exit 1
fi


pushd "$BUILD_DIR"


BUILD_ROOT="build"
#CONFIGURE_ARGS="--disable-docs
#                --disable-examples
#                --disable-postproc
#                --disable-webm-io
#                --disable-vp9-highbitdepth
#                --disable-vp9-postproc
#                --disable-vp9-temporal-denoising
#                --disable-unit-tests
#                --enable-realtime-only
#                --enable-vp8
#                --enable-multi-res-encoding"
                
CONFIGURE_ARGS="--disable-examples
                    --disable-unit-tests
                    --disable-tools
                    --disable-docs
                    --enable-vp8
                    --enable-vp9
                    --enable-webm-io
                    --enable-runtime-cpu-detect
                    --size-limit=8192x8192"
                
DIST_DIR="_dist"
FRAMEWORK_DIR="build/libvpx"
HEADER_DIR="${FRAMEWORK_DIR}/include/vpx"
SCRIPT_DIR="$SOURCE_DIR"
LIBVPX_SOURCE_DIR="$SOURCE_DIR"



ORIG_PWD="$(pwd)"



# Configures for the target specified by $1, and invokes make with the dist
# target using $DIST_DIR as the distribution output directory.
build_target() {

ARCH=$1
if [ "$1" = "arm64" ]; then
    local target="arm64-darwin24-gcc"
elif [ "$1" = "x86_64" ]; then
    local target="x86_64-darwin24-gcc"
else
  echo "Unsupported architecture $1"
  exit 1
fi

  local old_pwd="$(pwd)"
  local target_specific_flags=""


  mkdir "${ARCH}"
  cd "${ARCH}"
  cp -R ${LIBVPX_SOURCE_DIR}/* ./
  ./configure --target="${target}" \
    ${CONFIGURE_ARGS} ${EXTRA_CONFIGURE_ARGS} ${target_specific_flags} \

  export DIST_DIR
  make dist
  cd "${old_pwd}"
}



# Configures and builds each target specified by $1, and then builds
# VPX.framework.
build_framework() {
  local lib_list=""
  local targets=$ARCHS
  local target=""
  local target_dist_dir=""

  # Clean up from previous build(s).
  rm -rf "${BUILD_ROOT}" "${FRAMEWORK_DIR}"

  # Create output dirs.
  mkdir -p "${BUILD_ROOT}"
  mkdir -p "${HEADER_DIR}"

  cd "${BUILD_ROOT}"

  for target in ${targets}; do
    build_target "${target}"
    target_dist_dir="${BUILD_ROOT}/${target}/${DIST_DIR}"
    local suffix="a"
    lib_list="${lib_list} ${target_dist_dir}/lib/libvpx.${suffix}"
  done

  cd "${ORIG_PWD}"

  # The basic libvpx API includes are all the same; just grab the most recent
  # set.
  cp -p "${target_dist_dir}"/include/vpx/* "${HEADER_DIR}"

  # Build the fat library.
  mkdir "${FRAMEWORK_DIR}/lib"
  lipo -create ${lib_list} -output "${FRAMEWORK_DIR}/lib/libvpx.a"


}

build_framework "${TARGETS}"

popd
