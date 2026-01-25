#!/usr/bin/env bash
set -e

##
# Pre-requirements
# - env FUZZER: path to fuzzer dir
# - env TARGET_ARCH: target triplet for cross compilation (e.g. arm-linux-gnueabihf)
# - env OUT: path to directory where artifacts are stored
# - CC, CXX, ... must be set to the cross-compilation architecture

cd "${FUZZER}/repo/utils/aflpp_driver"

mkdir -p "${OUT}/driver"

${CC} -funroll-loops -g -fPIC -O3 -c \
    aflpp_qemu_driver.c -o "${OUT}/driver/aflpp_qemu_driver.o"

${AR} rcs "${OUT}/driver/libAFLQemuDriver.a" "${OUT}/driver/aflpp_qemu_driver.o"