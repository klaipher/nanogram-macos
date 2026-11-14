#!/bin/bash

# Enable error handling and verbose output
set -e
set -x

# Define the source directory and build directory from script arguments
SOURCE_DIR=$1

# Determine the absolute path for the build directory
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")
BUILD_DIR="${BUILD_DIR}build"

# Create the build directory if it does not exist
mkdir -p ${BUILD_DIR}

# Build from the core's klaipher/openh264 submodule (nanogram branch: v2.7.0 plus H.264 level 6.0-6.2 and the subcodec
# sprite mode, off by default): the one source iOS, Mac and Android pin. No clone, no download.
CORE_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd -P)}/../../submodules/telegram-ios"
CORE_OPENH264_DIR="${CORE_DIR}/third-party/openh264/openh264"
if [ ! -f "${CORE_OPENH264_DIR}/codec/api/wels/codec_ver.h" ]; then
    echo "error: ${CORE_OPENH264_DIR} is empty; run 'git submodule update --init --recursive'" >&2
    exit 1
fi
EXPECTED_SHA=$(git -C "${CORE_DIR}" ls-tree HEAD third-party/openh264/openh264 | awk '{print $3}')
ACTUAL_SHA=$(git -C "${CORE_OPENH264_DIR}" rev-parse HEAD 2>/dev/null || true)
if [ -n "${EXPECTED_SHA}" ] && [ -n "${ACTUAL_SHA}" ] && [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
    echo "error: openh264 checkout is ${ACTUAL_SHA}, the core pins ${EXPECTED_SHA}; run 'git submodule update --init --recursive'" >&2
    exit 1
fi
mkdir -p ${BUILD_DIR}/openh264
rsync -a --delete --exclude .git "${CORE_OPENH264_DIR}/" ${BUILD_DIR}/openh264/

# Define the output prefix for the final universal binary
USED_PREFIX=${BUILD_DIR}/output
mkdir -p ${USED_PREFIX}/lib
mkdir -p ${USED_PREFIX}/include

# Function to build for a specific architecture using make
buildOneArch() {
    arch=$1
    folder=${BUILD_DIR}/${arch}

    # Clean previous build artifacts if any exist
    make -C ${BUILD_DIR}/openh264 clean

    # Set appropriate compiler flags for each architecture
    if [ "$arch" = "arm64" ]; then
        export CFLAGS="-arch arm64"
    elif [ "$arch" = "x86_64" ]; then
        export CFLAGS="-arch x86_64"
    fi

    # Build the library for the specified architecture using make
    make -C ${BUILD_DIR}/openh264 ARCH=${arch} PREFIX=${folder} install-static

    # Manually copy the include files to the appropriate location
    mkdir -p ${folder}/include
    #cp -R ${BUILD_DIR}/openh264/include/* ${folder}/include/

    # Move the built static library to a temporary location for merging
    mv ${folder}/lib/libopenh264.a ${folder}/libopenh264.a
}

buildOneArch arm64

# Ensure the output include directory exists and copy headers from one architecture
cp -R ${BUILD_DIR}/arm64/include ${USED_PREFIX}/include

# Ensure the output directory exists before creating the universal binary
mkdir -p ${USED_PREFIX}/lib

# Use lipo to create a universal binary
lipo -create ${BUILD_DIR}/arm64/libopenh264.a -output ${USED_PREFIX}/lib/libopenh264.a

echo "Successfully created a universal binary at: ${USED_PREFIX}/lib/libopenh264.a"
echo "Headers are available at: ${USED_PREFIX}/include"
