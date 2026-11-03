#! /bin/sh

set -e
set -x



SOURCE_ARCHIVE="$1"
SOURCE_SHA256="c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f"
SOURCE_NAME="libjpeg-turbo-3.2.1"
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")
OUTPUTNAME="libjpeg.a"

MACOS_PLATFORMDIR="$PLATFORM_DIR"
MACOS_SYSROOT=($SDK_DIR)
DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET

echo "$SOURCE_SHA256  $SOURCE_ARCHIVE" | shasum -a 256 -c -

cd "$BUILD_DIR"
mkdir build
tar -xzf "$SOURCE_ARCHIVE" --directory build
SOURCE_DIR="${BUILD_DIR}build/$SOURCE_NAME"
cd build

for ARCH in $ARCHS
do

export CFLAGS="-Wall -arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET -funwind-tables"

mkdir $ARCH
cd $ARCH

touch toolchain.cmake
echo "set(CMAKE_SYSTEM_NAME Darwin)" >> toolchain.cmake
if [ $ARCH = "arm64" ]; then
echo "set(CMAKE_SYSTEM_PROCESSOR aarch64)" >> toolchain.cmake
else
echo "set(CMAKE_SYSTEM_PROCESSOR AMD64)" >> toolchain.cmake
fi
echo "set(CMAKE_C_COMPILER $(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang)" >> toolchain.cmake

# WITH_JPEG8 keeps the libjpeg v8 API (jpeg_mem_dest etc.) the binding and tg_owt were built against with mozjpeg.
cmake -G"Unix Makefiles" -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake -DCMAKE_OSX_SYSROOT=${MACOS_SYSROOT[0]} \
    -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=FALSE -DWITH_JPEG8=1 -DWITH_TOOLS=FALSE -DWITH_TESTS=FALSE \
    -DBUILD=10000 "$SOURCE_DIR"
make -j"$(sysctl -n hw.logicalcpu)" jpeg-static

cd ..

done


cd "$BUILD_DIR"
cd build

ARCH_COUNT=( $ARCHS )
ARCH_COUNT=${#ARCH_COUNT[@]}
if [[ $ARCH_COUNT -gt 1 ]] ; then
LIBRARIES=""
for ARCH in $ARCHS
do
LIBRARIES="$LIBRARIES ${BUILD_DIR}build/$ARCH/$OUTPUTNAME"
done
lipo -create -output $OUTPUTNAME $LIBRARIES
else
mv "${BUILD_DIR}build/$ARCHS/$OUTPUTNAME" "${BUILD_DIR}build/$OUTPUTNAME"
fi

set -- $ARCHS
cp "${BUILD_DIR}build/$1/jconfigint.h" "${BUILD_DIR}build/jconfigint.h"
cp "${BUILD_DIR}build/$1/jconfig.h" "${BUILD_DIR}build/jconfig.h"
cp "$SOURCE_DIR/src/"{jpeglib.h,jmorecfg.h,jerror.h,turbojpeg.h} "${BUILD_DIR}build/"
