#!/bin/bash

apt-get update && \
    apt-get install -y git make autoconf automake libtool cmake nasm \
        zlib1g-dev:"${TARGET_ARCH_DEB}" liblzma-dev:"${TARGET_ARCH_DEB}" \
        libjpeg-turbo8-dev:"${TARGET_ARCH_DEB}" wget