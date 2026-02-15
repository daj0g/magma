# Dockerfile.target - Target-specific image for Magma Pirate
#
# Usage:
#   docker build -t magma-pirate/libpng:arm32 \
#       --build-arg base_image=magma-pirate-base:arm32 \
#       --build-arg target=libpng \
#       --build-arg canaries=1 \
#       -f Dockerfile.target .
#
# Build arguments:
#   - base_image: Base image name (default: magma-pirate-base:arm32)
#   - target: Target name from targets/ (default: libpng)
#   - canaries: Enable canary detection (set to 1)
#   - fixes: Enable bug fixes (set to 1)
#   - isan: Enable fatal canaries (set to 1)
#   - harden: Enable hardened canaries (set to 1)

ARG base_image=pirate/base
FROM ${base_image}

################################################################################
# I. Environment setup
################################################################################
ARG target=libpng
ARG target_image
ARG bug
ARG optimization=1
ARG canary_mode=1
ARG precompiled_lib
ARG canaries
ARG fixes
ARG isan
ARG harden

ENV TARGET_NAME="${target}"
ENV TARGET="${MAGMA_R}/targets/${TARGET_NAME}"
ENV IMG_NAME_TARGET="${target_image}"
ENV BUG="${bug:-}"
ENV CANARY_MODE="${canary_mode}"
ENV OPTIMIZATION="${optimization}"
ENV PRECOMPILED_LIB_NAME="${precompiled_lib}"
ENV PRECOMPILED_LIB=${precompiled_lib:+${PIRATE}/precompiled/${TARGET_NAME}/${BUG}/${precompiled_lib}}

USER root:root
# Create target directory
RUN mkdir -p ${TARGET} && \
    chown magma:magma ${TARGET} && \
    chmod 755 ${TARGET}

# Copy target files
COPY --chown=magma:magma ${HOST_CONTEXT_ROOT}/tools/pirate/ ${PIRATE}
COPY --chown=magma:magma ${HOST_CONTEXT_ROOT}/targets/${TARGET_NAME} ${TARGET}

################################################################################
# II. Magma instrumentation
################################################################################
USER magma:magma
ENV MAGMA_BUILD_FLAGS="-include ${MAGMA}/src/canary.h \
    ${canaries:+-DMAGMA_ENABLE_CANARIES} \
    ${fixes:+-DMAGMA_ENABLE_FIXES} \
    ${isan:+-DMAGMA_FATAL_CANARIES} \
    ${harden:+-DMAGMA_HARDEN_CANARIES}"
ENV BUILD_FLAGS="-g -fPIC"

ENV CFLAGS="${MAGMA_BUILD_FLAGS} ${BUILD_FLAGS}"
ENV CXXFLAGS="${MAGMA_BUILD_FLAGS} ${BUILD_FLAGS}"
ENV LDFLAGS="-L${OUT} -g"
ENV LIBS="${LIBS} -l:magma.o -lrt"

RUN ${PIRATE}/scripts/magma_build_cross.sh

################################################################################
# III. Target
################################################################################
USER root:root
# Install target dependencies
RUN ${PIRATE}/scripts/${TARGET_NAME}_preinstall_cross.sh

USER magma:magma
# Retrieves target source code
RUN ${TARGET}/fetch.sh
# Forward port bug
RUN ${PIRATE}/scripts/apply_patches.sh

# last -O flag takes precedence
ENV CFLAGS="${CFLAGS} -O${OPTIMIZATION}"
ENV CXXFLAGS="${CXXFLAGS} -O${OPTIMIZATION}"
RUN ${PIRATE}/scripts/${TARGET_NAME}_build_cross.sh

ENTRYPOINT ["/bin/bash"]