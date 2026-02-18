#!/bin/bash

apt-get update && \
    apt-get install -y git make autoconf automake libtool \
        pkg-config zlib1g-dev:"${TARGET_ARCH_DEB}" liblzma-dev:"${TARGET_ARCH_DEB}"
