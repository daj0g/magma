#!/bin/bash
set -e

##############################################################################
# run_all_opt.sh — Build and launch campaigns for all three optimization levels
#
# Usage:
#   ./run_sweep.sh [piraterc]            Build O1/O2/O3 + run all detached
#   ./run_sweep.sh --no-build [piraterc] Skip build, just launch all
#
# All campaigns run detached (--detach is implied).
# Pass any additional flags accepted by run.sh (except --shell).
##############################################################################

PIRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PIRATE}/scripts/util.sh"

for opt in 1 2 3; do
    log_info "=== Optimization level O${opt} ==="
    OPTIMIZATION=$opt "${PIRATE}/run.sh" --detach "$@"
done