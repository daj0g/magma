#!/bin/bash
set -e

##
# Pre-requirements:
# - env TARGET: path to target work dir
# - env OUT: path to directory where artifacts are stored
# - env CC, CXX, FLAGS, LIBS, etc...
##

if [ ! -d "$TARGET/repo" ]; then
    echo "fetch.sh must be executed first."
    exit 1
fi

cd "${TARGET}/repo"

# we still need .h files

# Only build libpng, IF $PRECOMPILED_LIB not set
if [ -z "$PRECOMPILED_LIB" ]; then
    autoreconf -f -i
    ./configure \
    --host="${TARGET_ARCH}" \
    --with-libpng-prefix=MAGMA_ \
    --enable-shared \
    --disable-static \
    CFLAGS="${CFLAGS}" \
    CXXFLAGS="${CXXFLAGS}" \
    LDFLAGS="${LDFLAGS}"

    make -j$(nproc) clean
    make -j$(nproc)
    # Copy shared library to OUT
    cp -a .libs/*.so* "${OUT}/"
else
    autoreconf -f -i
    ./configure \
    --host="${TARGET_ARCH}" \
    --enable-shared \
    --disable-static \
    CFLAGS="${CFLAGS}" \
    CXXFLAGS="${CXXFLAGS}" \
    LDFLAGS="${LDFLAGS}"

    make -j$(nproc) pnglibconf.h

    cp -a "${PRECOMPILED_LIB}" "${OUT}/"
    ln -sf "$(basename "${PRECOMPILED_LIB}")" "${OUT}/libpng16.so"
fi


# build libpng_read_fuzzer harness/program
${CXX} ${CXXFLAGS} -O2 -std=c++11 \
    -I. \
    contrib/oss-fuzz/libpng_read_fuzzer.cc \
    -o "${OUT}/libpng_read_fuzzer" \
    ${LDFLAGS} \
    ${LIBS} \
    -lpng16 -lz -lm


echo "[*] Verifying harness..."
file "${OUT}/libpng_read_fuzzer"
/usr/bin/${TARGET_ARCH}-readelf -d "${OUT}/libpng_read_fuzzer" | grep NEEDED || true