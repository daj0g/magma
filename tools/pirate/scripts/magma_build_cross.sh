#!/bin/bash
set -e

##
# Pre-requirements:
# - env MAGMA: path to Magma support files
# - env OUT: path to directory where artifacts are stored
# - env SHARED: path to directory shared with host (to store results)

# FIX: Guard canary.h against Assembly files BEFORE we build anything.
# This prevents the "bad instruction" error later in libpng
if ! grep -q '__ASSEMBLER__' "${MAGMA}/src/canary.h"; then
  sed -i '1i#ifndef __ASSEMBLER__' "${MAGMA}/src/canary.h"
  echo "#endif" >> "${MAGMA}/src/canary.h"
fi

MAGMA_STORAGE="${SHARED}/canaries.raw"

${CC} ${CFLAGS} -O0 -D"MAGMA_STORAGE=\"${MAGMA_STORAGE}\"" -c "${MAGMA}/src/canary.c" \
    -fPIC -I "${MAGMA}/src/" -o "${OUT}/canary.o"

${CC} ${CFLAGS} -O0 -D"MAGMA_STORAGE=\"${MAGMA_STORAGE}\"" -c "${MAGMA}/src/storage.c" \
    -fPIC -I "${MAGMA}/src/" -o "${OUT}/storage.o"

${LD} -r "${OUT}/canary.o" "${OUT}/storage.o" -o "${OUT}/magma.o"
rm "${OUT}/canary.o" "${OUT}/storage.o"