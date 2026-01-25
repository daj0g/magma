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

# build libpng library
cd "${TARGET}/repo"
autoreconf -f -i
./configure \
--host="${TARGET_ARCH}" \
--prefix="${OUT}/libpng_install" \
--with-libpng-prefix=MAGMA_ \
--enable-shared \
--disable-static \
CFLAGS="${CFLAGS}" \
CXXFLAGS="${CXXFLAGS}" \
LDFLAGS="${LDFLAGS} -L${DEPS_DIR}/lib" \
CPPFLAGS="-I${DEPS_DIR}/include"
    ## --host:   Cross-compile, sets CC, CXX, AR, ... automatically to host var
    ## --prefix: Installation destination
    ## --with-libpng-prefix: Prefix func inside libpng with MAGMA_

make -j$(nproc) clean
make -j$(nproc)
make install

# Copy shared library to OUT
cp -a "${OUT}/libpng_install/lib"/*.so* "${OUT}/"

# build libpng_read_fuzzer harness/program
${CXX} ${CXXFLAGS} -std=c++11 \
    -I"${OUT}/libpng_install/include" \
    -I"${DEPS_DIR}/include" \
    -I. \
    contrib/oss-fuzz/libpng_read_fuzzer.cc \
    -o "${OUT}/libpng_read_fuzzer" \
    -L"${DEPS_DIR}/lib" \
    ${LDFLAGS} \
    ${LIBS} \
    -lpng16 -lz -lm \

    # -L"${OUT}" \

echo "[*] Verifying harness..."
file "${OUT}/libpng_read_fuzzer"
/usr/bin/arm-linux-gnueabihf-readelf -d "${OUT}/libpng_read_fuzzer" | grep NEEDED || true
