#!/bin/bash
set -e

##
# Pre-requirements
# - env PIRATE: path to pirate dir
# - env FUZZER: path to fuzzer dir
# - env OUT: path to directory where artifacts are stored
# - CC, CXX, ... must be set to the cross-compilation architecture



gcc -fPIC -shared \
    "${PIRATE}/scripts/persistent_hook.c" \
    -o "${OUT}/persistent_hook.so" \
    -I"${FUZZER}/repo/qemu_mode/qemuafl"