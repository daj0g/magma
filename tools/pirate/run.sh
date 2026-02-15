#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/scripts/util.sh"

PIRATE="$(dirname "${BASH_SOURCE[0]}")"
source "${PIRATE}/piraterc"

# Build-time vars
export TARGET_NAME="${TARGET_NAME:-libpng}"
export CANARY_MODE="${CANARY_MODE:-1}"
export OPTIMIZATION="${OPTIMIZATION:-1}"
export BUG="${BUG:-}"

# Runtime vars
POLL="${POLL:-5}"
TIMEOUT="${TIMEOUT:-10m}"
WORKERS="${WORKERS:-2}"
SHARED="${SHARED:-${PIRATE}/output}"

# Build image (skip with -n/--no-build)
if [[ "${1:-}" != "-n" && "${1:-}" != "--no-build" ]]; then
    "${PIRATE}/build.sh"
fi

# Derive image name (must match build.sh logic)
IMG_NAME_TARGET="pirate/${TARGET_NAME}/c${CANARY_MODE}_o${OPTIMIZATION}_${BUG:-all}"
IMG_NAME_TARGET=${IMG_NAME_TARGET,,}


# Run container
log_info "Starting campaign: ${IMG_NAME_TARGET}"
mkdir -p "${SHARED}"

docker run --rm -it \
-e PROGRAM="${PROGRAM}" \
-e POLL="${POLL}" \
-e TIMEOUT="${TIMEOUT}" \
-e WORKERS="${WORKERS}" \
-v "${SHARED}:/magma_shared" \
"${IMG_NAME_TARGET}" \
/magma/tools/pirate/scripts/start.sh

###################################################






# if [ ${#BUGS[@]} -gt 0 ]; then
#     for bug in "${BUGS[@]}"; do
#         if [ ! -f "${MAGMA_R}/targets/${TARGET_NAME}/patches/bugs/${bug}.patch" ]; then
#             log_error "No patch file for $bug found."
#             exit 1
#         fi
#         b=${b:+$b+}$(( 10#${bug//[[:alpha:]]/} ))
#     done
#     b="b$b"
# else
#     b="ball"
# fi
###################################################