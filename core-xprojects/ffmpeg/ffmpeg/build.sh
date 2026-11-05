#!/bin/sh

set -e
set -x


SOURCE_DIR=$1

BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")
BUILD_DIR="${BUILD_DIR}build/"

FAT="${BUILD_DIR}ffmpeg"

SCRATCH="${BUILD_DIR}scratch"
THIN="${BUILD_DIR}thin"

PKG_CONFIG="$SOURCE_DIR/pkg-config"






rm -rf $BUILD_DIR || true
mkdir -p $BUILD_DIR || true


LIBOPUS_PATH="${BUILD_DIR}../../libopus/build/libopus"
LIBVPX_PATH="${BUILD_DIR}../../libvpx/build/libvpx"
LIBDAV1D_PATH="${BUILD_DIR}../../dav1d/build/dav1d"

FF_VERSION="9.0.2"
if [ ! -r "$SOURCE_DIR/ffmpeg-$FF_VERSION" ]; then
	DETECTED_SOURCES=`find "$SOURCE_DIR" -maxdepth 1 -type d -name 'ffmpeg-*'`
	if [ `echo "$DETECTED_SOURCES" | grep -c .` -eq 1 ]; then
		FF_VERSION=`basename "$DETECTED_SOURCES" | sed 's/^ffmpeg-//'`
	fi
fi
SOURCE="$SOURCE_DIR/ffmpeg-$FF_VERSION"

GAS_PREPROCESSOR_PATH="$SOURCE_DIR/gas-preprocessor.pl"




export PATH="$SOURCE_DIR:$PATH"

LIB_NAMES="libavcodec libavformat libavutil libswresample"


# The shared list (decoders, demuxers, parsers, disabled Apple frameworks) is the iOS repo's
# ffmpeg-common-flags.sh, so the two apps cannot drift. What is added here is Mac only: AudioToolbox (the
# alac/gsm decoders), the native AAC decoder and the VideoToolbox hwaccels; the Mac builds no muxers.
. "$SOURCE_DIR/ffmpeg-common-flags.sh"

CONFIGURE_FLAGS="$FFMPEG_COMMON_FLAGS \
                 --enable-audiotoolbox \
                 --enable-decoder=aac,alac_at,gsm_ms_at \
                 --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,av1_videotoolbox \
                 "

EXTRA_CFLAGS="-DCONFIG_SAFE_BITSTREAM_READER=1 -fstack-protector-strong"
CONFIGURE_FLAGS="$CONFIGURE_FLAGS --disable-debug"

COMPILE="y"

DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET


if [ "$COMPILE" ]
then
	if [ ! `which pkg-config` ]; then
		echo 'pkg-config not found'
		exit 1
	else
		echo "PATH=$PATH"
		echo "pkg-config=$(which pkg-config)"
	fi
	if [ ! `which "$GAS_PREPROCESSOR_PATH"` ]; then
		echo '$GAS_PREPROCESSOR_PATH not found.'
		exit 1
	fi

	if [ ! -r $SOURCE ]; then
		echo "FFmpeg source not found at $SOURCE"
		exit 1
	fi

	for ARCH in $ARCHS
	do
		echo "building $ARCH..."
		mkdir -p "$SCRATCH/$ARCH"
		pushd "$SCRATCH/$ARCH"

		

        CFLAGS="$EXTRA_CFLAGS -arch $ARCH"
		if [ "$ARCH" = "x86_64" ]
		then
		    PLATFORM="MacOSX"
		    CFLAGS="$CFLAGS -mmacosx-version-min=$DEPLOYMENT_TARGET"
		else
		    PLATFORM="MacOSX"
		    CFLAGS="$CFLAGS -mmacosx-version-min=$DEPLOYMENT_TARGET"
		fi

		XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
		CC="xcrun -sdk $XCRUN_SDK clang"

		if [ "$ARCH" = "arm64" ]
		then
		    AS="$CC"
		else
		    AS="$GAS_PREPROCESSOR_PATH -- $CC"
		fi

		CXXFLAGS="$CFLAGS"
		LDFLAGS="$CFLAGS"

		CONFIGURED_MARKER="$THIN/$ARCH/configured_marker"
		CONFIGURED_MARKER_CONTENTS=""
		if [ -r "$CONFIGURED_MARKER" ]
		then
			CONFIGURED_MARKER_CONTENTS=`cat "$CONFIGURED_MARKER"`
		fi
		if [ "$CONFIGURED_MARKER_CONTENTS" = "$CONFIGURE_FLAGS" ]
		then
			echo "1" >/dev/null
		else
			mkdir -p "$THIN/$ARCH"
			TMPDIR=${TMPDIR/%\/} "$SOURCE/configure" \
			    --target-os=darwin \
			    --arch=$ARCH \
			    --cc="$CC" \
			    --as="$AS" \
			    $CONFIGURE_FLAGS \
			    --extra-cflags="$CFLAGS" \
			    --extra-ldflags="$LDFLAGS" \
			    --prefix="$THIN/$ARCH" \
			    --pkg-config="$PKG_CONFIG" \
                --pkg-config-flags="--libopus_path $LIBOPUS_PATH --libvpx_path $LIBVPX_PATH --libdav1d_path $LIBDAV1D_PATH" \
			|| exit 1
			echo "$CONFIGURE_FLAGS" > "$CONFIGURED_MARKER"
		fi

		CORE_COUNT=`sysctl -n hw.logicalcpu`
		make -j$CORE_COUNT install $EXPORT || exit 1

		popd
	done
fi


mkdir -p "$FAT"/lib
set - $ARCHS
for LIB in "$THIN/$1/lib/"*.a
do
    LIB_NAME="$(basename $LIB)"
    echo "LIPO_INPUT command find \"$THIN\" -name \"$LIB_NAME\""
    LIPO_INPUT=`find "$THIN" -name "$LIB_NAME"`
    lipo -create $LIPO_INPUT -output "$FAT/lib/$LIB_NAME" || exit 1
done
cp -rf "$THIN/$1/include" "$FAT"
