#!/bin/bash
set -e

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -z "$1" ]; then
        set -- "./piraterc"
    fi

    # load the configuration file (piraterc)
    set -a
    source "$1"
    set +a
fi

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
    OPTIMIZATION="${OPTIMIZATION:-1}"
    ISAN="${ISAN:-}"
    HARDEN="${HARDEN:-}"
    TARGET_ARCH="arm-linux-gnueabihf"
    TARGET_ARCH_DEB="armhf"
    BUG=${BUG:-}
    PRECOMPILED_LIB_NAME=${PRECOMPILED_LIB_NAME:-}
    PRECOMPILED_LIB="${PRECOMPILED_LIB_NAME:+${PIRATE}/precompiled/${TARGET_NAME}/${BUG}/${PRECOMPILED_LIB_NAME}}"

    WORKDIR="${WORKDIR:-./workdir}"
    WORKDIR="$(realpath "$WORKDIR")"
    LOGDIR="$WORKDIR/log"
    POCDIR="$WORKDIR/poc"


    if [ -n "${BUG}" ]; then
        if [ ! -f "${MAGMA_R}/targets/${TARGET_NAME}/patches/bugs/${BUG}.patch" ]; then
            log_error "No patch file for ${BUG} found."
            exit 1
        fi
    fi

    if [ "$CANARY_MODE" -eq 4 ]; then
        if [ -z "$BUG" ]; then
            log_error "\$BUG variable needs to be set in CANARY_MODE=4"
            exit 1
        fi
        if [ ! -f "$PRECOMPILED_LIB" ]; then
            log_error "Precompiled lib missing ${PRECOMPILED_LIB:-'(empty)'}"
            exit 1
        fi
        if [ -z "$OPTIMIZATION" ] || [ "$OPTIMIZATION" -gt 3 ]; then
            log_error "Please set the correct optimization level."
            log_error "${OPTIMIZATION:-'(empty)'} not possible"
            exit 1
        fi
    else
        if [ -n "$PRECOMPILED_LIB_NAME" ]; then
            log_warn "Precompiled lib defined, but canary mode not 4!"
        fi
    fi

    (( OPTIMIZATION > 3 )) && OPTIMIZATION=3 || true      # cap at 3
    (( CANARY_MODE > 4 )) && CANARY_MODE=1 || true          # set 1 by default


    # Docker Settings
    DOCKERFILE_BASE="${PIRATE}/base.Dockerfile"
    DOCKERFILE_TARGET="${PIRATE}/target.Dockerfile"
    IMG_NAME_BASE="pirate/base"
    IMG_NAME_TARGET="$(derive_image_name)"

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
    mkdir -p "$LOGDIR"
    mkdir -p "$POCDIR"

    log_success "Work directory set up." "${BUILDLOG}"
    return 0
}

################################################################################
# Summary
################################################################################
print_build_summary() {
    local red=$'\033[0;31m'
    local green=$'\033[0;32m'
    local yellow=$'\033[0;33m'
    local blue=$'\033[0;34m'
    local grey=$'\033[38;5;245m'
    local darkgrey=$'\033[38;5;238m'
    local bold=$'\033[1m'
    local off=$'\033[0m'

    local prepath=${PRECOMPILED_LIB/$PIRATE/${grey}\$PIRATE${red}}
    prepath=${prepath/O$OPTIMIZATION/${yellow}O$OPTIMIZATION${red}}
    prepath=${prepath/$BUG/${yellow}$BUG${red}}
    prepath=${prepath/$TARGET_NAME/${yellow}$TARGET_NAME${red}}

    local summary
    summary=$(cat << EOF
 ${blue}${bold}
 ==============================================================================
                                     BUILD SUMMARY
 ============================================================================== ${off}
${bold}  Magma Root:${off}        $MAGMA_R                                      ${off}
${bold}  Workdir:${off}           ${WORKDIR/$MAGMA_R/${grey}\$MAGMA_R${off}}    ${off}
${bold}  Pirate dir:${off}        ${PIRATE/$MAGMA_R/${grey}\$MAGMA_R${off}}     ${off}

${bold}  Fuzzer:${off}            ${FUZZER_NAME}                                ${off}
${bold}  Target:${off}            ${yellow}${TARGET_NAME}                       ${off}
${bold}  Program/Harness:${off}   ${PROGRAM_NAME}                               ${off}

${bold}  Canary Mode:${off}       ${yellow}${CANARY_MODE/4/${red}4 -> Check library!}${off}
${bold}  Precompiled Lib:${off}   ${red}${prepath:-${darkgrey}N/A}              ${off}
${bold}  Bugs enabled:${off}      ${yellow}${BUG:-all}                          ${off}
${bold}  Optimization:${off}      ${yellow}${OPTIMIZATION}                      ${off}
${bold}  ISAN:${off}              ${green}${ISAN:-${darkgrey}disabled} ${off}
${bold}  HARDEN:${off}            ${HARDEN:-${darkgrey}disabled}                ${off}
${bold}  Magma Build Args:${off}  ${MAGMA_BUILD_ARGS[*]}                        ${off}

${bold}  Target Triplet:${off}    ${green}$TARGET_ARCH                          ${off}
${bold}  Host Triplet:${off}      $(gcc -dumpmachine)                           ${off}

${bold}  Docker Image:${off}      ${green}$IMG_NAME_TARGET                     ${off}
${bold}  Dockerfile:${off}        ${DOCKERFILE_TARGET/$MAGMA_R/${grey}\$MAGMA_R${off}}${off}
${bold}  Build context:${off}     $MAGMA_R                                      ${off}

${bold}  Logfile:${off}           ${BUILDLOG/$WORKDIR/${grey}\$WORKDIR${off}} ${off}${blue}${bold}
 ================================================================================${off}
EOF
)
    echo -e "$summary"
    echo -e "$summary"| sed 's/\x1b\[[0-9;]*m//g' >> "$BUILDLOG"
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

    if [ -n "$ISAN" ]; then
        MAGMA_BUILD_ARGS+=("--build-arg" "isan=1")
    fi
    if [ -n "$HARDEN" ]; then
        MAGMA_BUILD_ARGS+=("--build-arg" "harden=1")
    fi

    log_info "MAGMA_BUILD_ARGS: ${MAGMA_BUILD_ARGS[*]}"
    log_info "Build context: $MAGMA_R" "$BUILDLOG"

    # Check by user
    print_build_summary
    if [ -t 0 ]; then
        read -rp "Check the summary above. Proceed with build? [Y/n] " answer
        case "${answer,,}" in
            n|no) log_info "Build cancelled by user." "$BUILDLOG"; exit 2 ;;
        esac
    fi

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
        --build-arg target_image="$IMG_NAME_TARGET" \
        --build-arg bug="$BUG" \
        --build-arg precompiled_lib="$PRECOMPILED_LIB_NAME" \
        --build-arg canary_mode="$CANARY_MODE" \
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

    setup_directories

    docker_build
    print_build_summary
    log_success "Build was successful!" "$BUILDLOG"
    log_info "Run the docker image ${IMG_NAME_TARGET}." "$BUILDLOG"
}

trap "cleanup" EXIT

main