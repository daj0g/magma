#!/bin/bash
set -e

##
# Pre-requirements:
# - env TARGET: path to target work dir
# - env OUT: path to directory where artifacts are stored
# - env CC, CXX, FLAGS, LIBS, etc...
# - env TARGET_ARCH: cross-compilation triplet (e.g. arm-linux-gnueabihf)
# - env PIRATE: path to pirate tool directory
#
# System dependencies (install in Dockerfile):
#   apt-get install -y libjpeg-dev:armhf liblzma-dev:armhf zlib1g-dev:armhf
##

if [ ! -d "$TARGET/repo" ]; then
    echo "fetch.sh must be executed first."
    exit 1
fi

################################################################################
# Build libtiff
################################################################################
WORK="${TARGET}/work"
rm -rf "${WORK}"
mkdir -p "${WORK}"/{lib,include}

cd "${TARGET}/repo"

./autogen.sh
./configure \
    --host="${TARGET_ARCH}" \
    --prefix="${WORK}" \
    --enable-shared \
    --disable-static \
    --disable-jbig \
    CFLAGS="${CFLAGS}" \
    CXXFLAGS="${CXXFLAGS}" \
    LDFLAGS="${LDFLAGS}"

# Only build libtiff if $PRECOMPILED_LIB is not set
if [ -z "$PRECOMPILED_LIB" ]; then
    echo "[*] Building libtiff as shared library..."

    make -j$(nproc) clean
    make -j$(nproc)
    make install

    # Copy shared libraries to OUT
    cp -a "${WORK}/lib"/*.so* "${OUT}/"
else
    echo "[*] Using precompiled libtiff: ${PRECOMPILED_LIB}"

    make -j$(nproc) -C libtiff tif_config.h tiffconf.h

    cp -a "${PRECOMPILED_LIB}" "${OUT}/"

    # static linker (compile time)
    ln -sf "$(basename "${PRECOMPILED_LIB}")" "${OUT}/libtiff.so"
    # dynamic linker / loader (runtime)
    ln -sf "$(basename "${PRECOMPILED_LIB}")" "${OUT}/libtiff.so.5"
fi

################################################################################
# Build harness
################################################################################
echo "[*] Building tiff_read_rgba_fuzzer harness..."
# NOTE: I can not use tiffcp right now, because it can't handle
# input from stdin.
# TODO: Maybe possible with persisten mode

# tiff_read_rgba_fuzzer
${CXX} ${CXXFLAGS} -O2 -std=c++11 \
    -I"${WORK}/include" \
    contrib/oss-fuzz/tiff_read_rgba_fuzzer.cc \
    -o "${OUT}/tiff_read_rgba_fuzzer" \
    ${LDFLAGS} \
    ${LIBS} \
    -L"${WORK}/lib" \
    -ltiffxx -ltiff -lz -lm -ljpeg -llzma

# tiffcp
cp "${WORK}/bin/tiffcp" "${OUT}/"

echo "[*] Verifying harness..."
file "${OUT}/tiff_read_rgba_fuzzer"
/usr/bin/${TARGET_ARCH}-readelf -d "${OUT}/tiff_read_rgba_fuzzer" | grep NEEDED || true

