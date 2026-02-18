#!/bin/bash
set -e

##############################################################################
# run.sh — Build image (optional) and launch a fuzzing campaign
#
# Usage:
#   ./run.sh [piraterc]              Build image + run campaign
#   ./run.sh --no-build [piraterc]   Skip build, just run campaign
#   ./run.sh --detach [piraterc]     Run campaign in background
#   ./run.sh --shell [piraterc]      Skip build, open interactive shell
#
# Configuration is read from piraterc (default: ./piraterc).
# Environment variables override piraterc values.
##############################################################################

PIRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PIRATE}/scripts/util.sh"

# Parse flags
NO_BUILD=0
INTERACTIVE=0
DETACH=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --no-build) NO_BUILD=1; shift ;;
        --detach)   DETACH=1; shift;;
        --shell)    NO_BUILD=1; INTERACTIVE=1; shift ;;
        *)          log_error "Unknown flag: $1"; exit 1 ;;
    esac
done

# Load configuration
RCFILE="${1:-${PIRATE}/piraterc}"
if [ ! -f "$RCFILE" ]; then
    log_error "Config file not found: $RCFILE"
    exit 1
fi
set -a
source "$RCFILE"
set +a


# Derive image name (same as in build.sh)
IMG_NAME_TARGET="$(derive_image_name)"

################################################################################
# Build (unless --no-build)
################################################################################
if [ "$NO_BUILD" -eq 0 ]; then
    if docker image inspect "$IMG_NAME_TARGET" &>/dev/null && [ -t 0 ]; then
        log_warn "Image already exists: ${IMG_NAME_TARGET}"
        read -rp "Rebuild and overwrite? [Y/n] " answer
        case "${answer,,}" in
            n|no) log_info "Skipping build, using existing image." ;;
            *) "${PIRATE}/build.sh" "$RCFILE" ;;
        esac
    else
        "${PIRATE}/build.sh" "$RCFILE"
    fi
fi

# Verify image exists
if ! docker image inspect "$IMG_NAME_TARGET" &>/dev/null; then
    log_error "Docker image not found: ${IMG_NAME_TARGET}"
    log_error "Run without --no-build to build it first."
    exit 1
fi

################################################################################
# Shared directories
################################################################################
WORKDIR="$(realpath "${WORKDIR:-./workdir}")"
mkdir -p "$WORKDIR"

################################################################################
# Launch container
################################################################################
CONTAINER_BASE="${IMG_NAME_TARGET//\//_}_${PROGRAM_NAME}"
CONTAINER_N=1
while docker container inspect "${CONTAINER_BASE}_${CONTAINER_N}" &>/dev/null; do
    ((CONTAINER_N++))
done
CONTAINER_NAME="${CONTAINER_BASE}_${CONTAINER_N}"

DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    -v "${WORKDIR}:/magma_shared"
    # Runtime variables (override piraterc defaults baked into the image)
    -e "PROGRAM_NAME=${PROGRAM_NAME:-}"
    -e "PROGRAM_ARGS=${PROGRAM_ARGS:-}"
    -e "CORPUS_NAME=${CORPUS_NAME:-}"
    -e "POLL=${POLL:-5}"
    -e "TIMEOUT=${TIMEOUT:-5m}"
    -e "WORKERS=${WORKERS:-2}"
    -e "INCLUDE_POV=${INCLUDE_POV:-}"
)

# if [ "$DETACH" -eq 0 ]; then
#     DOCKER_ARGS+=(--rm)
# fi

if [ "$INTERACTIVE" -eq 1 ]; then
    log_info "Opening interactive shell in ${IMG_NAME_TARGET}"
    docker run -it "${DOCKER_ARGS[@]}" "$IMG_NAME_TARGET"
elif [ "$DETACH" -eq 1 ]; then
    log_info "Starting detached campaign: ${CONTAINER_NAME} (timeout=${TIMEOUT:-5m})"
    docker run -d "${DOCKER_ARGS[@]}" "$IMG_NAME_TARGET" \
        /magma/tools/pirate/start.sh
    log_info "Logs: docker logs -f ${CONTAINER_NAME}"
else
    log_info "Starting campaign: ${IMG_NAME_TARGET} (timeout=${TIMEOUT:-5m})"
    docker run "${DOCKER_ARGS[@]}" "$IMG_NAME_TARGET" \
        /magma/tools/pirate/start.sh
fi