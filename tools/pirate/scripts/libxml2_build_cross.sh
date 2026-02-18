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
#   apt-get install -y liblzma-dev:armhf zlib1g-dev:armhf
##

if [ ! -d "$TARGET/repo" ]; then
    echo "fetch.sh must be executed first."
    exit 1
fi

################################################################################
# Build libxml2
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
    --with-http=no \
    --with-python=no \
    --with-lzma=yes \
    --with-threads=no \
    CFLAGS="${CFLAGS}" \
    CXXFLAGS="${CXXFLAGS}" \
    LDFLAGS="${LDFLAGS}"

# Only build libxml2 if $PRECOMPILED_LIB is not set
if [ -z "$PRECOMPILED_LIB" ]; then
    echo "[*] Building libxml2 as shared library..."

    make -j$(nproc) clean
    make -j$(nproc)
    make install

    # Copy shared libraries to OUT
    cp -a "${WORK}/lib"/*.so* "${OUT}/"
else
    echo "[*] Using precompiled libxml2: ${PRECOMPILED_LIB}"

    # Build headers
    make -j$(nproc) -C include

    cp -a "${PRECOMPILED_LIB}" "${OUT}/"

    # static linker (compile time)
    ln -sf "$(basename "${PRECOMPILED_LIB}")" "${OUT}/libxml2.so"
    # dynamic linker / loader (runtime)
    ln -sf "$(basename "${PRECOMPILED_LIB}")" "${OUT}/libxml2.so.2"
fi

################################################################################
# Build harnesses
################################################################################
echo "[*] Building libxml2 harnesses..."

for harness in libxml2_xml_read_memory_fuzzer libxml2_xml_reader_for_file_fuzzer; do
    ${CXX} ${CXXFLAGS} -O2 -std=c++11 \
        -I"${WORK}/include/libxml2" \
        -Iinclude \
        -I"${TARGET}/src/" \
        "${TARGET}/src/${harness}.cc" \
        -o "${OUT}/${harness}" \
        ${LDFLAGS} \
        ${LIBS} \
        -L"${WORK}/lib" \
        -lxml2 -lz -llzma -lm
done

# xmllint
cp "${WORK}/bin/xmllint" "${OUT}/" 2>/dev/null || true

echo "[*] Verifying harness..."
file "${OUT}/libxml2_xml_read_memory_fuzzer"
/usr/bin/${TARGET_ARCH}-readelf -d "${OUT}/libxml2_xml_read_memory_fuzzer" | grep NEEDED || true