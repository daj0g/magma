# Dockerfile.base - Base image for Magma Pirate (AFL++ QEMU mode fuzzing)
#
# Usage:
#   docker build -t magma-pirate-base:arm32 \
#       --build-arg target_arch=arm-linux-gnueabihf \
#       --build-arg target_arch_deb=armhf \
#       --build-arg user_id="$(id -u)" \
#       --build-arg group_id="$(id -g)" \
#       -f Dockerfile.base .
#
# This base image contains:
#   - Cross-compilation toolchain
#   - QEMU user-mode emulation
#   - AFL++ with QEMU mode support
#   - Magma monitor

FROM ubuntu:20.04

################################################################################
# I. Environment Setup
################################################################################
ARG DEBIAN_FRONTEND=noninteractive

## Magma directory hierarchy
# magma_root is relative to the docker-build's working directory
# The Docker image must be built in the root of the magma directory
# So we must provide the context using $MAGMA_R
ENV HOST_CONTEXT_ROOT=./
ENV MAGMA_R=/magma

ARG fuzzer=aflplusplus
ARG target_arch=arm-linux-gnueabihf
ARG target_arch_deb=armhf
ARG user_id=1000
ARG group_id=1000

ENV FUZZER_NAME=${fuzzer}
ENV FUZZER=${MAGMA_R}/fuzzers/${FUZZER_NAME}
ENV PIRATE=${MAGMA_R}/tools/pirate
ENV TARGET_ARCH=${target_arch}
ENV TARGET_ARCH_DEB=${target_arch_deb}
ENV USERID=${user_id}
ENV GROUPID=${group_id}

ENV MAGMA=${MAGMA_R}/magma
ENV OUT=/magma_out
ENV SHARED=/magma_shared

# Compiler Variables x86
ENV CC=/usr/bin/gcc
ENV CXX=/usr/bin/g++
ENV LD=/usr/bin/ld
ENV AR=/usr/bin/ar
ENV AS=/usr/bin/as
ENV NM=/usr/bin/nm
ENV RANLIB=/usr/bin/ranlib

# Compiler variables cross
ENV TARGET_CC=/usr/bin/${TARGET_ARCH}-gcc
ENV TARGET_CXX=/usr/bin/${TARGET_ARCH}-g++
ENV TARGET_AR=/usr/bin/${TARGET_ARCH}-ar
ENV TARGET_LD=/usr/bin/${TARGET_ARCH}-ld
ENV TARGET_NM=/usr/bin/${TARGET_ARCH}-nm
ENV TARGET_RANLIB=/usr/bin/${TARGET_ARCH}-ranlib

ENV QEMU_LD_PREFIX=/usr/${TARGET_ARCH}
ENV LD_LIBRARY_PATH=${OUT}

################################################################################
# II. Initial OS and environment setup
################################################################################
# Use bash. Ubuntu defaults to dash!
SHELL ["/bin/bash", "-c"]

USER root:root

RUN apt-get update && apt-get install -y sudo

# Trouble shooting tools
RUN apt-get install -y \
    neovim file gawk binutils-${TARGET_ARCH}

# Install cross-compilation toolchain and QEMU
RUN apt-get install -y \
    gcc-${TARGET_ARCH} g++-${TARGET_ARCH} \
    qemu-user qemu-user-static

# Add target architecture repositories
RUN dpkg --add-architecture ${TARGET_ARCH_DEB}

RUN echo "deb [arch=amd64] http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse" > /etc/apt/sources.list && \
    echo "deb [arch=amd64] http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=amd64] http://security.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=${TARGET_ARCH_DEB}] http://ports.ubuntu.com/ubuntu-ports/ focal main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=${TARGET_ARCH_DEB}] http://ports.ubuntu.com/ubuntu-ports/ focal-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=${TARGET_ARCH_DEB}] http://ports.ubuntu.com/ubuntu-ports/ focal-security main restricted universe multiverse" >> /etc/apt/sources.list

RUN apt-get update

# Create magma user
RUN mkdir -p /home && \
    groupadd -g ${GROUPID} magma && \
    useradd -l -u ${USERID} -K UMASK=0000 -d /home -g magma magma && \
    chown magma:magma /home

RUN echo "magma:magma" | chpasswd && \
    usermod -a -G sudo magma && \
    echo "magma ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/magma && \
    chmod 0440 /etc/sudoers.d/magma

# Create directories
RUN mkdir -p ${OUT} ${SHARED} ${MAGMA} ${FUZZER} && \
    chown magma:magma ${OUT} ${SHARED} ${MAGMA} ${FUZZER} && \
    chmod 755 ${OUT} ${SHARED} ${MAGMA} ${FUZZER}

# Copy magma and fuzzer files
COPY --chown=magma:magma ${HOST_CONTEXT_ROOT}/magma ${MAGMA}
COPY --chown=magma:magma ${HOST_CONTEXT_ROOT}/fuzzers/${FUZZER_NAME} ${FUZZER}

################################################################################
# III. Magma Monitor
################################################################################
USER root:root
RUN ${MAGMA}/preinstall.sh

USER magma:magma
RUN ${MAGMA}/prebuild.sh
# Copy monitor to shared folder, for inspection from host
RUN cp ${OUT}/monitor ${SHARED}/monitor

################################################################################
# IV. Fuzzer - AFL++
################################################################################
USER root:root
RUN ${FUZZER}/preinstall.sh
# Install QEMU mode dependencies
RUN apt-get install -y \
    ninja-build pkg-config libglib2.0-dev build-essential python3-dev \
    automake git flex bison libpixman-1-dev python3-setuptools

USER magma:magma
RUN ${FUZZER}/fetch.sh
RUN ${FUZZER}/build.sh

# Build AFL++ QEMU mode
RUN cd ${FUZZER}/repo/qemu_mode && \
    CROSS=${TARGET_CC} CPU_TARGET=${TARGET_ARCH%%-*} ./build_qemu_support.sh

#===============================================================================
# From now on everything is cross compiled
#===============================================================================
ENV CC=${TARGET_CC}
ENV CXX=${TARGET_CXX}
ENV AR=${TARGET_AR}
ENV LD=${TARGET_LD}
ENV NM=${TARGET_NM}
ENV RANLIB=${TARGET_RANLIB}

COPY --chown=magma:magma \
    ${HOST_CONTEXT_ROOT}/tools/pirate/scripts/aflpp_driver_cross.sh \
    ${PIRATE}/scripts/

# Build AFL++ QEMU Driver
RUN ${PIRATE}/scripts/aflpp_driver_cross.sh
ENV LIBS="${OUT}/driver/libAFLQemuDriver.a"

ENTRYPOINT ["/bin/bash"]