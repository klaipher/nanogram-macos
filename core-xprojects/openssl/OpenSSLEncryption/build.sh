#!/bin/bash

set -x
set -e

SRC_DIR="$1"
BUILD_DIR=$(echo "$(cd "$(dirname "$3")"; pwd -P)/$(basename "$3")")



cd $BUILD_DIR

rm -rf build || true
mkdir build

OUT_DIR="${BUILD_DIR}build"


NAME="openssl-3.5.9";

CROSS_TOP_MAC="$(xcode-select -p)/Platforms/MacOSX.platform"
CROSS_SDK_MAC="MacOSX.sdk"

# The tag is checked against the commit it named when it was pinned; a moved tag stops the build.
OPENSSL_COMMIT="45e844fa2a14ec92d146bd8f5778ac130b6625fb"
git clone -b openssl-3.5.9 --depth 1 https://github.com/openssl/openssl build/${NAME}
if [ "$(git -C build/${NAME} rev-parse HEAD)" != "$OPENSSL_COMMIT" ]; then
  echo "error: openssl-3.5.9 is $(git -C build/${NAME} rev-parse HEAD), expected $OPENSSL_COMMIT" >&2
  exit 1
fi


SOURCE_DIR="$OUT_DIR/${NAME}"



export CROSS_COMPILE=`xcode-select --print-path`/Toolchains/XcodeDefault.xctoolchain/usr/bin/

function build_for ()
{
  DIR="$(pwd)"
  cd "$SOURCE_DIR"

  PLATFORM="$1"
  ARCH="$2"
  CROSS_TOP_ENV="CROSS_TOP_$3"
  CROSS_SDK_ENV="CROSS_SDK_$3"

  make clean || true

  export CROSS_TOP="${!CROSS_TOP_ENV}"
  export CROSS_SDK="${!CROSS_SDK_ENV}"

  MINIMAL_FLAGS=(\
    "no-shared" \
    "no-afalgeng" \
    "no-aria" \
    "no-asan" \
    "no-async" \
    "no-autoalginit" \
    "no-autoerrinit" \
    "no-autoload-config" \
    "no-bf" \
    "no-blake2" \
    "no-buildtest-c++" \
    "no-camellia" \
    "no-capieng" \
    "no-cast" \
    "no-chacha" \
    "no-cmac" \
    "no-cms" \
    "no-comp" \
    "no-crypto-mdebug" \
    "no-crypto-mdebug-backtrace" \
    "no-ct" \
    "no-deprecated" \
    "no-des" \
    "no-devcryptoeng" \
    "no-dgram" \
    "no-dh" \
    "no-dsa" \
    "no-dtls" \
    "no-dynamic-engine" \
    "no-ec" \
    "no-ec2m" \
    "no-ecdh" \
    "no-ecdsa" \
    "no-ec_nistp_64_gcc_128" \
    "no-egd" \
    "no-engine" \
    "no-err" \
    "no-external-tests" \
    "no-filenames" \
    "no-fuzz-libfuzzer" \
    "no-fuzz-afl" \
    "no-gost" \
    "no-heartbeats" \
    "no-idea" \
    "no-makedepend" \
    "no-md2" \
    "no-md4" \
    "no-mdc2" \
    "no-msan" \
    "no-multiblock" \
    "no-nextprotoneg" \
    "no-pinshared" \
    "no-ocb" \
    "no-ocsp" \
    "no-pic" \
    "no-poly1305" \
    "no-posix-io" \
    "no-psk" \
    "no-rc2" \
    "no-rc4" \
    "no-rc5" \
    "no-rfc3779" \
    "no-rmd160" \
    "no-scrypt" \
    "no-sctp" \
    "no-shared" \
    "no-siphash" \
    "no-sm2" \
    "no-sm3" \
    "no-sm4" \
    "no-sock" \
    "no-srp" \
    "no-srtp" \
    "no-sse2" \
    "no-ssl" \
    "no-ssl-trace" \
    "no-static-engine" \
    "no-stdio" \
    "no-tests" \
    "no-tls" \
    "no-ts" \
    "no-ubsan" \
    "no-ui-console" \
    "no-unit-test" \
    "no-whirlpool" \
    "no-weak-ssl-ciphers" \
    "no-zlib" \
    "no-zlib-dynamic" \
  )

  DEFAULT_FLAGS=(\
    "no-shared" \
    "no-asm" \
    "no-ssl3" \
    "no-comp" \
    "no-hw" \
    "no-engine" \
    "no-async" \
    "no-tests" \
  )

  # The memory-safety hardening Nanogram.xcconfig gives the app's own C (Configure passes unknown
  # dash options to the compiler).
  ./Configure $PLATFORM -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -ftrivial-auto-var-init=zero -fstack-protector-strong \
    no-shared no-tests \
    no-quic no-engine no-dso no-autoload-config no-legacy no-sm2 no-sm3 no-sm4 no-aria no-camellia no-seed \
    no-idea no-bf no-cast no-rc2 no-rc4 no-rc5 no-mdc2 no-whirlpool no-srp no-gost no-ct no-cms no-ts no-ssl3 \
    no-comp no-docs no-ml-dsa no-slh-dsa \
    --prefix="${ABS_TMP_DIR}/${ARCH}" || exit 1
  
  make build_libs || exit 2
  unset CROSS_TOP
  unset CROSS_SDK

  cd "$DIR"
}

# patch "$SOURCE_DIR/Configurations/10-main.conf" < "$PWD/OpenSSLEncryption/patch-conf.diff" || exit 1


for ARCH in $ARCHS
do
  build_for darwin64-$ARCH-cc $ARCH MAC
  mkdir build/$ARCH
  mv "build/${NAME}/libssl.a" "build/$ARCH/libssl.a"
  mv "build/${NAME}/libcrypto.a" "build/$ARCH/libcrypto.a"
done


ARCH_COUNT=( $ARCHS )
ARCH_COUNT=${#ARCH_COUNT[@]}
if [[ $ARCH_COUNT -gt 1 ]] ; then
LIBSSLA=""
LIBCRYPTO=""
mkdir -p ${BUILD_DIR}build/openssl/lib
mv $SOURCE_DIR/include ${BUILD_DIR}build/openssl/include
for ARCH in $ARCHS
do
LIBSSLA="$LIBSSLA ${BUILD_DIR}build/$ARCH/libssl.a"
LIBCRYPTO="$LIBCRYPTO ${BUILD_DIR}build/$ARCH/libcrypto.a"
done
lipo -create -output ${BUILD_DIR}build/openssl/lib/libssl.a $LIBSSLA
lipo -create -output ${BUILD_DIR}build/openssl/lib/libcrypto.a $LIBCRYPTO
else
mkdir -p ${BUILD_DIR}build/openssl/lib
mv $SOURCE_DIR/include ${BUILD_DIR}build/openssl/include
mv "${BUILD_DIR}build/$ARCHS/libssl.a" "${BUILD_DIR}build/openssl/lib/libssl.a"
mv "${BUILD_DIR}build/$ARCHS/libcrypto.a" "${BUILD_DIR}build/openssl/lib/libcrypto.a"
fi

# OpenSSL 3 marks the 1.1 APIs that upstream's callers use (tgcalls, EncryptionProvider, MtProtoKit) deprecated;
# they still work in 3.5, and porting those callers is upstream's job, so keep their builds warning-free.
cat >> "${BUILD_DIR}build/openssl/include/openssl/configuration.h" <<'EOF_SUPPRESS'

#ifndef OPENSSL_SUPPRESS_DEPRECATED
# define OPENSSL_SUPPRESS_DEPRECATED
#endif
EOF_SUPPRESS


#cp -r "${TMP_DIR}/$ARCH/include" "${TMP_DIR}/"
#if [ "$ARCH" == "arm64" ]; then
#  patch -p3 "${TMP_DIR}/include/openssl/opensslconf.h" < "$SRC_DIR/patch-include.patch" || exit 1
#fi
#
#DFT_DIST_DIR="$OUT_DIR/out"
#rm -rf "$DFT_DIST_DIR"
#mkdir -p "$DFT_DIST_DIR"
#
#DIST_DIR="${DIST_DIR:-$DFT_DIST_DIR}"
#mkdir -p "${DIST_DIR}"
#cp -r "${TMP_DIR}/include" "${TMP_DIR}/$ARCH/lib" "${DIST_DIR}"
