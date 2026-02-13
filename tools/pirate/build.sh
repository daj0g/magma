#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/scripts/util.sh"
################################################################################
# Variable Definition
################################################################################
setup_variables() {
    log_info "Setting up variables ..."

    # General
    MAGMA_R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" 2>/dev/null && pwd)"
    PIRATE="${MAGMA_R}/tools/pirate"

    # Magma Settings
    FUZZER_NAME="aflplusplus"
    TARGET_NAME="${TARGET_NAME:-libpng}"
    CANARY_MODE="${CANARY_MODE:-1}"
    TARGET_ARCH="arm-linux-gnueabihf"
    TARGET_ARCH_DEB="armhf"
    BUG=${BUG:-}
    PRECOMPILED_LIB_NAME=${PRECOMPILED_LIB_NAME:-}
    PRECOMPILED_LIB="${PRECOMPILED_LIB_NAME:+${PIRATE}/precompiled/${TARGET_NAME}/${BUG}/${PRECOMPILED_LIB_NAME}}"

    WORKDIR="${WORKDIR:-./workdir}"
    WORKDIR="$(realpath "$WORKDIR")"
    ARDIR="$WORKDIR/ar"
    CACHEDIR="$WORKDIR/cache"
    LOGDIR="$WORKDIR/log"
    POCDIR="$WORKDIR/poc"


    if [ -n "${BUG}" ]; then
        if [ ! -f "${MAGMA_R}/targets/${TARGET_NAME}/patches/bugs/${BUG}.patch" ]; then
            log_error "No patch file for ${BUG} found."
            exit 1
        fi
    else
        if [ -n "${PRECOMPILED_LIB}" ]; then
            log_error "\$PRECOMPILED_LIB_NAME set, but \$BUG not set."
            log_info "Unset \$PRECOMPILED_LIB_NAME or specify a bug."
            exit 1
        fi
    fi

    if [ "$CANARY_MODE" -eq 4 ]; then
        if [ ! -f "$PRECOMPILED_LIB" ]; then
            log_error "Precompiled lib missing ${PRECOMPILED_LIB:-'(empty)'}"
            exit 1
        fi
        if [ -z "$OPTIMIZATION" ] || [ "$OPTIMIZATION" -gt 3 ]; then
            log_error "Please set the correct optimization level."
            log_error "${OPTIMIZATION:-'(empty)'} not possible"
            exit 1
        fi

    fi

    OPTIMIZATION="${OPTIMIZATION:-1}"
    (( OPTIMIZATION > 3 )) && OPTIMIZATION=3        # cap at 3


    # Docker Settings
    DOCKERFILE_BASE="${PIRATE}/base.Dockerfile"
    DOCKERFILE_TARGET="${PIRATE}/target.Dockerfile"
    # IMG_NAME_BASE="pirate-base-${TARGET_ARCH%%-*}"
    IMG_NAME_BASE="pirate/base"
    IMG_NAME_TARGET="${IMG_NAME_TARGET:-pirate/${TARGET_NAME}/c${CANARY_MODE}_o${OPTIMIZATION}_${BUG:-all}}"
    IMG_NAME_TARGET="${IMG_NAME_TARGET,,}"

    # Logging
    BUILDLOG="${LOGDIR}/${IMG_NAME_TARGET//\//_}_build.log"

    log_success "Initial variables set up."
    return 0
}

################################################################################
# Directory setup
################################################################################
setup_directories() {
    log_info "Setting up directories ..."
    mkdir -p "$WORKDIR"
    mkdir -p "$ARDIR"
    mkdir -p "$CACHEDIR"
    mkdir -p "$LOGDIR"
    mkdir -p "$POCDIR"

    log_success "Work directory set up." "${BUILDLOG}"
    return 0
}


################################################################################
# Docker build
################################################################################
docker_build() {
    MAGMA_BUILD_ARGS=()

    log_info "Building Docker image ${IMG_NAME_TARGET} ..." "${BUILDLOG}"

    if [ -n "$BUG" ]; then
        MAGMA_BUILD_ARGS+=("--build-arg" "bug=${BUG}")
    fi

    case "${CANARY_MODE}" in
        1) MAGMA_BUILD_ARGS+=("--build-arg" "canaries=1") ;;
        2) ;; # No additional args for no canaries
        3) MAGMA_BUILD_ARGS+=("--build-arg" "fixes=1")    ;;
        4) log_warn "Build with precompiled lib $PRECOMPILED_LIB";; # No additional args for precompiled lib
        *)
            log_error "Invalid canary value ${CANARY_MODE}." "$BUILDLOG"
            msg="Valid inputs are 1 (Canaries), 2 (None),"
            msg+="3 (Fixes), 4 (precompiled lib)"
            log_error "$msg" "$BUILDLOG"
            exit 1
            ;;
    esac

    ############################################################################
    # TODO: WHAT DO THESE TWO OPTIONS DO??
    #
    if [ -n "$ISAN" ]; then
        MAGMA_BUILD_ARGS+=("--build-arg" "isan=1")
    fi
    if [ -n "$HARDEN" ]; then
        MAGMA_BUILD_ARGS+=("--build-arg" "harden=1")
    fi
    ############################################################################

    log_info "MAGMA_BUILD_ARGS: ${MAGMA_BUILD_ARGS[*]}"
    log_info "Build context: $MAGMA_R" "$BUILDLOG"

    # Build Docker base image
    # OS init, fuzzer (incl. qemu mode), Magma monitor
    log_info "Building base Docker image ..." "$BUILDLOG"
    if ! docker build -t "$IMG_NAME_BASE" \
        --build-arg fuzzer="$FUZZER_NAME" \
        --build-arg target_arch="$TARGET_ARCH" \
        --build-arg target_arch_deb="$TARGET_ARCH_DEB" \
        --build-arg user_id="$(id -u)" \
        --build-arg group_id="$(id -g)" \
        -f "$DOCKERFILE_BASE" "$MAGMA_R" \
        > >(while IFS= read -r line; do
            log_docker "$line" "$BUILDLOG"
        done) 2>&1
    then
        log_error "Docker build failed for ${IMG_NAME_BASE}" "${BUILDLOG}"
        log_error "Check ${BUILDLOG}."
        exit 1
    fi

    log_success "Docker image ${IMG_NAME_BASE} built successfully." "${BUILDLOG}"


    # Build Docker target image
    # Magma instrumentation, and instrumented target
    log_info "Building target Docker image ..." "$BUILDLOG"
    if ! docker build -t "$IMG_NAME_TARGET" \
        --build-arg base_image="$IMG_NAME_BASE" \
        --build-arg target="$TARGET_NAME" \
        --build-arg img_name="$IMG_NAME_TARGET" \
        --build-arg precompiled_lib="$PRECOMPILED_LIB_NAME" \
        --build-arg optimization="$OPTIMIZATION" \
        "${MAGMA_BUILD_ARGS[@]}" \
        -f "$DOCKERFILE_TARGET" "$MAGMA_R" \
        > >(while IFS= read -r line; do
            log_docker "$line" "$BUILDLOG"
        done) 2>&1
    then
        log_error "Docker build failed for ${IMG_NAME_TARGET}" "${BUILDLOG}"
        log_error "Check ${BUILDLOG}."
        exit 1
    fi

    log_success "Docker image ${IMG_NAME_TARGET} built successfully." "${BUILDLOG}"
    return 0
}


################################################################################
# Cleanup routine
################################################################################
cleanup() {
    log_info "Cleaning up..." "${BUILDLOG}"

    jobs -p | xargs -r kill 2>/dev/null || true

    log_success "Everything clean. Exit." "${BUILDLOG}"
}


################################################################################
# Summary
################################################################################
print_summary() {
    local red=$'\033[0;31m'
    local green=$'\033[0;32m'
    local yellow=$'\033[0;33m'
    local blue=$'\033[0;34m'
    local grey=$'\033[38;5;245m'
    local bold=$'\033[1m'
    local off=$'\033[0m'

    cat << EOF | tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$BUILDLOG")
 ${blue}${bold}
 ================================================================================
                                     SUMMARY
 ================================================================================${off}
 ${bold}Magma Root:${off}      $MAGMA_R
 ${bold}Workdir:${off}         $WORKDIR
 ${bold}Pirate dir:${off}      $PIRATE
 ${bold}Dockerfile:${off}      ${grey}\$MAGMAROOT/${off}${DOCKERFILE_TARGET#*"${MAGMA_R}"/}
 ${bold}Docker Image:${off}    ${red}$IMG_NAME_TARGET${off}
 ${bold}Build context:${off}   $MAGMA_R
 ${bold}Canary Mode:${off}     $CANARY_MODE
 ${bold}MAGMA_BUILDARGS:${off} ${MAGMA_BUILD_ARGS[*]}
 ${bold}Fuzzer:${off}          ${FUZZER_NAME}
 ${bold}Bugs enabled:${off}    ${BUG:-all}
 ${bold}Optimization:${off}    -O${OPTIMIZATION}

 ${bold}Target Triplet:${off}  ${yellow}$TARGET_ARCH${off}
 ${bold}Host Triplet:${off}    $(gcc -dumpmachine)

 ${bold}Logfile:${off}         ${grey}\$WORKDIR/${off}${BUILDLOG#*"${WORKDIR}"/}

EOF
}


################################################################################
#  Main
################################################################################
main() {
    #Set up variables
    setup_variables


    # Check Magma directory
    if [ ! -d "${MAGMA_R}" ]; then
        log_error "Magma directory not found or invalid." "${BUILDLOG}"
        exit 1
    fi

    # Check Pirate Directory
    if [ ! -d "${PIRATE}" ]; then
        log_error "Pirate directory not found or invalid." "${BUILDLOG}"
        exit 1
    fi

    # Check Docker and dockerfile
    if ! command -v docker &> /dev/null; then
        log_error "Docker executable not found. Please install docker." "${BUILDLOG}"
        exit 1
    fi

    # if [ ! -f "${DOCKERFILE}" ]; then
    #     log_error "Dockerfile ${DOCKERFILE} not found." "${BUILDLOG}"
    #     exit 1
    # fi

    setup_directories
    docker_build
    log_success "Build was successful!" "$BUILDLOG"
    print_summary
}

trap "exit 1" SIGINT SIGTERM
trap "cleanup" EXIT

main