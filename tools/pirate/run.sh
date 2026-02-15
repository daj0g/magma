#!/bin/bash
set -e

##############################################################################
# run.sh — Build image (optional) and launch a fuzzing campaign
#
# Usage:
#   ./run.sh [piraterc]              Build image + run campaign
#   ./run.sh --no-build [piraterc]   Skip build, just run campaign
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
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --no-build) NO_BUILD=1; shift ;;
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

################################################################################
# Derive image name (shared logic in util.sh)
################################################################################
IMG_NAME_TARGET="$(derive_image_name)"

################################################################################
# Build (unless --no-build)
################################################################################
if [ "$NO_BUILD" -eq 0 ]; then
    "${PIRATE}/build.sh" "$RCFILE"
fi

# Verify image exists
if ! docker image inspect "$IMG_NAME_TARGET" &>/dev/null; then
    log_error "Docker image not found: ${IMG_NAME_TARGET}"
    log_error "Run without --no-build to build it first."
    exit 1
fi

################################################################################
# Shared volume (mount WORKDIR into the container as /magma_shared)
################################################################################
WORKDIR="$(realpath "${WORKDIR:-./workdir}")"
mkdir -p "$WORKDIR"

################################################################################
# Launch container
################################################################################
DOCKER_ARGS=(
    --rm
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

if [ "$INTERACTIVE" -eq 1 ]; then
    log_info "Opening interactive shell in ${IMG_NAME_TARGET}"
    docker run -it "${DOCKER_ARGS[@]}" "$IMG_NAME_TARGET"
else
    log_info "Starting campaign: ${IMG_NAME_TARGET} (timeout=${TIMEOUT:-5m})"
    docker run "${DOCKER_ARGS[@]}" "$IMG_NAME_TARGET" \
        /magma/tools/pirate/start.sh
fi