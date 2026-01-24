#!/usr/bin/env bash

source ./util.sh

################################################################################
# Variable Defintion
################################################################################
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
        2) canary_args="" ;;
        3) canary_args="--build-arg fixes=1" ;;
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
    if ! docker build -t "${IMG_NAME}" \
        --build-arg fuzzer="$FUZZER" \
        --build-arg target="$TARGET" \
        --build-arg target_arch="$TARGET_ARCH" \
        --build-arg user_id="$(id -u)" \
        --build-arg group_id="$(id -g)" \
        $CANARY_ARGS \
        -f "$DOCKERFILE" "$MAGMA_R" \
        > "${BUILDLOG}" 2>&1
    then
        log_error "Docker build filed for ${IMG_NAME}" "${BUILDLOG}"
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
    red="$(tput setaf 1)"
    green="$(tput setaf 2)"
    yellow="$(tput setaf 3)"
    blue="$(tput setaf 4)"
    bold='\033[1m'
    bold="$(tput bold)"
    grey="$(tput setaf 245)"
    reset="$(tput sgr0)"


    cat << EOF
 ${blue}================================================================================
                                     SUMMARY
 ================================================================================${reset}
 ${bold}Magmadir:${reset}        $MAGMA_R
 ${bold}Workdir:${reset}         $WORKDIR
 ${bold}Target Triplet:${reset}  ${yellow}$TARGET_ARCH${reset}
 ${bold}Host Triplet:${reset}    $(gcc -dumpmachine)
 ${bold}Timeout:${reset}         $TIMEOUT
 ${bold}Repeat:${reset}          $REPEAT
 ${bold}Canary Mode:${reset}     $CANARY_MODE
 ${bold}Fuzzer:${reset}          ${FUZZER}
 ${bold}Dockerfile:${reset}      ${grey}\$MAGMADIR/${reset}${DOCKERFILE#*$MAGMA_R/}
 ${bold}Docker Image:${reset}    ${IMG_NAME}

 ${bold}Logfile:${reset}         ${grey}\$WORKDIR/${reset}${BUILDLOG#*$WORKDIR/}
EOF
}


################################################################################
#  Main
################################################################################
main() {
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