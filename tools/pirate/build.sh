#!/usr/bin/env bash

source ./util.sh

################################################################################
# Variable Defintion
################################################################################
setup_variables() {
    # General
    MAGMA_R="${MAGMA_R:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" 2>/dev/null && pwd)}"
    PIRATE="${PIRATE:-${MAGMA_R}/tools/pirate}"

    # Magma Settings
    FUZZER="aflplusplus"
    TARGET="${TARGET:-libpng}"
    CANARY_MODE="${CANARY_MODE:-1}"

    WORKDIR="${WORKDIR:-./workdir}"
    WORKDIR="$(realpath "$WORKDIR")"

    ARDIR="$WORKDIR/ar"
    CACHEDIR="$WORKDIR/cache"
    LOGDIR="$WORKDIR/log"
    POCDIR="$WORKDIR/poc"

    # Docker Settings
    DOCKERFILE="${DOCKERFILE:-${PIRATE}/DOCKERFILE_PIRATE}"
    IMG_NAME="magma-arm32/${FUZZER}/${TARGET}"

    # Cross-compile
    TARGET_ARCH="arm-linux-gnueabihf"


    BUILDLOG="${LOGDIR}/${IMG_NAME//\//_}_build.log"

    log_info "Initial variables set up." "${BUILDLOG}"
    return 0
}

################################################################################
# Directory setup
################################################################################
setup_directories() {
    mkdir -p "$WORKDIR"
    mkdir -p "$ARDIR"
    mkdir -p "$CACHEDIR"
    mkdir -p "$LOGDIR"
    mkdir -p "$POCDIR"

    log_info "Work directory set up." "${BUILDLOG}"
    return 0
}


################################################################################
# Docker build
################################################################################
docker_build() {
    local fuzzer_dir="${MAGMA_R}fuzzers/${FUZZER}"

    log_info "Bulding Docker image ${IMG_NAME} ..." "${BUILDLOG}"

    local canary_args=""
    case "${CANARY_MODE}" in
        1) canary_args="--build-arg canaries=1" ;;
        2) canary_args=""                       ;;
        3) canary_args="--build-arg fixes=1"    ;;
        *)
            log_error "Invalid canary value ${CANARY_MODE}." "$BUILDLOG"
            log_error "Valid inputs are 1 (Canaries), 2 (None), 3 (Fixes)" \
                "$BUILDLOG"
            exit 1
            ;;
    esac

    ############################################################################
    # TODO: WHAT DO THESE TWO OPTIONS DO??
    #
    if [ -n "$ISAN" ]; then
        canary_args="$canary_args --build-arg isan=1"
    fi
    if [ -n "$HARDEN" ]; then
        canary_args="$canary_args --build-arg harden=1"
    fi
    ############################################################################

    # Build Docker image
    if ! docker build -t "$IMG_NAME" \
        --build-arg fuzzer="$FUZZER" \
        --build-arg target="$TARGET" \
        --build-arg target_arch="$TARGET_ARCH" \
        --build-arg user_id="$(id -u)" \
        --build-arg group_id="$(id -g)" \
        $CANARY_ARGS \
        -f "$DOCKERFILE" "$MAGMA_R" \
        > >(while IFS= read -r line; do
            log_docker "$line" "$BUILDLOG"
        done) 2>&1

    then
        log_error "Docker build failed for ${IMG_NAME}" "${BUILDLOG}"
        log_error "Check ${BUILDLOG}." "${BUILDLOG}"
        exit 1

    fi

    log_info "Docker image ${IMG_NAME} built successfully." "${BUILDLOG}"
    return 0

}


################################################################################
# Cleanup routine
################################################################################
cleanup() {
    log_info "Cleaning up..." "${BUILDLOG}"

    jobs -p | xargs -r kill 2>/dev/null || true

    # Stop running docker containers
    docker ps -q --filter "ancestor=magma-cross/*" 2>/dev/null | \
        xargs -r docker stop 2>/dev/null || true

    log_info "Everything clean. Exit." "${BUILDLOG}"
}


################################################################################
# Summary
################################################################################
print_summary() {
    local red=$'\e[0;31m'
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
 ${bold}Dockerfile:${off}      ${grey}\$MAGMAROOT/${off}${DOCKERFILE#*"${MAGMA_R}"/}
 ${bold}Docker Image:${off}    ${IMG_NAME}
 ${bold}Timeout:${off}         $TIMEOUT
 ${bold}Repeat:${off}          $REPEAT
 ${bold}Canary Mode:${off}     $CANARY_MODE
 ${bold}Fuzzer:${off}          ${FUZZER}

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
        log_error "Magma direcotry not found or invalid." "${BUILDLOG}"
        exit 1
    fi

    # Check Pirate Directory
    if [ ! -d "${PIRATE}" ]; then
        log_error "Pirate directory not found or invalid." "${BUILDLOG}"
        exit 1
    fi

    # Check Docker and dockerfile
    if ! command docker &> /dev/null; then
        log_error "Docker executable not found. Please install docker." "${BUILDLOG}"
        exit 1
    fi

    # if [ ! -f "${DOCKERFILE}" ]; then
    #     log_error "Dockerfile ${DOCKERFILE} not found." "${BUILDLOG}"
    #     exit 1
    # fi

    setup_directories
    docker_build

}

trap "exit 1" SIGINT SIGTERM
trap "cleanup; print_summary;" EXIT

main