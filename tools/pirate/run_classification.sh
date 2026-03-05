#!/bin/bash
set -e

##############################################################################
# run_classification.sh — Classification orchestrator for campaign crashes
#
# Iterates over all AFL++ instances in one or more source campaigns,
# replays each instance's crashes against all three library variants
# (vulnerable, oracle, patched), and classifies each crash using the
# differential crash matrix.
#
# Usage:
#   ./run_classification.sh [--no-build] [classificationrc]
#
# Options:
#   --no-build    Skip building the classification Docker image
#
# Configuration is read from classificationrc (default: ./classificationrc).
#
# classificationrc variables:
#   WORKDIR         Working directory (default: ./workdir)
#   TARGET_NAME     Target library (e.g. libpng)
#   BUG             Bug identifier (e.g. PNG006)
#   PROGRAM_NAME    Harness binary name
#   PROGRAM_ARGS    Harness arguments (optional)
#   OPTIMIZATION    Optimization level (1/2/3)
#   TIMEOUT_EACH    Per-input timeout in seconds (default: 10)
#   CRASH_SOURCE    Where to find crashes (default: "fuzzing")
#                   "fuzzing" — Phase 3: campaigns/.../findings/<instance>/crashes/
#                   "replay"  — Phase 2: replay/<target>/<bug>/o<OPT>/campaign_<N>/<instance>/crashes/
#   CAMPAIGNS       Space-separated campaign numbers or ranges
#                   (e.g. "315 316 317" or "315-320" or "315-318 400 500-502")
##############################################################################

PIRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAGMA_R="$(cd "${PIRATE}/../../" && pwd)"
source "${PIRATE}/scripts/util.sh"

################################################################################
# Parse flags
################################################################################
NO_BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=1; shift ;;
        --*)        log_error "Unknown flag: $1"; exit 1 ;;
        *)          break ;;
    esac
done

################################################################################
# Load configuration
################################################################################
RCFILE="${1:-${PIRATE}/classificationrc}"
if [ ! -f "$RCFILE" ]; then
    log_error "Config file not found: $RCFILE"
    exit 1
fi
set -a
# shellcheck disable=SC1090
source "$RCFILE"
set +a

################################################################################
# Expand campaign ranges (e.g. "200-205 310" → "200 201 202 203 204 205 310")
################################################################################
expanded=""
for token in $CAMPAIGNS; do
    if [[ "$token" == *-* ]]; then
        lo="${token%%-*}"
        hi="${token##*-}"
        expanded+=" $(seq -s ' ' "$lo" "$hi")"
    else
        expanded+=" $token"
    fi
done
CAMPAIGNS="${expanded# }"

################################################################################
# Derive image names for all three variants
################################################################################
# CANARY_MODE is read by derive_image_name
# shellcheck disable=SC2034
CANARY_MODE=1; vuln_image="$(derive_image_name)"
# shellcheck disable=SC2034
CANARY_MODE=3; oracle_image="$(derive_image_name)"
# shellcheck disable=SC2034
CANARY_MODE=4; patched_image="$(derive_image_name)"

CLASSIFICATION_IMAGE="pirate/classification/${TARGET_NAME:-libpng}/${BUG,,:-all}/o${OPTIMIZATION:-1}"

WORKDIR="$(realpath "${WORKDIR:-./workdir}")"
CRASH_SOURCE="${CRASH_SOURCE:-fuzzing}"
REPLAY_DIR="${WORKDIR}/replay/${TARGET_NAME}/${BUG}/o${OPTIMIZATION}"
CLASSIFICATION_DIR="${WORKDIR}/classification/${TARGET_NAME}/${BUG}/o${OPTIMIZATION}"

log_info "Vulnerable image: ${vuln_image}"
log_info "Oracle image:     ${oracle_image}"
log_info "Patched image:    ${patched_image}"
log_info "Classification image:     ${CLASSIFICATION_IMAGE}"
log_info "Crash source:     ${CRASH_SOURCE}"
log_info "Output:           ${CLASSIFICATION_DIR}/"
log_info "Campaigns:        ${CAMPAIGNS}"
log_info "Program:          ${PROGRAM_NAME} ${PROGRAM_ARGS:-}"

################################################################################
# Build classification image (once)
################################################################################
if [ "$NO_BUILD" -eq 0 ]; then
    for img in "$vuln_image" "$oracle_image" "$patched_image"; do
        if ! docker image inspect "$img" &>/dev/null; then
            log_error "Required image not found: $img"
            log_error "Build it first with ./run.sh or ./build.sh"
            exit 1
        fi
    done

    log_info "Building classification image: ${CLASSIFICATION_IMAGE}"
    docker build -t "$CLASSIFICATION_IMAGE" \
        --build-arg vulnerable_image="$vuln_image" \
        --build-arg oracle_image="$oracle_image" \
        --build-arg patched_image="$patched_image" \
        -f "${PIRATE}/classification.Dockerfile" \
        "$MAGMA_R"
    log_info "Classification image built: ${CLASSIFICATION_IMAGE}"
fi

if ! docker image inspect "$CLASSIFICATION_IMAGE" &>/dev/null; then
    log_error "Classification image not found: ${CLASSIFICATION_IMAGE}"
    log_error "Run without --no-build to build it first."
    exit 1
fi

################################################################################
# Main loop: iterate over campaigns and instances
################################################################################
total_campaigns=0
total_instances=0
total_skipped=0
total_errors=0

for campaign_num in $CAMPAIGNS; do
    log_info "=== Campaign ${campaign_num} ==="

    # Locate instance directories based on crash source
    if [ "$CRASH_SOURCE" = "replay" ]; then
        instances_base="${REPLAY_DIR}/campaign_${campaign_num}"
    else
        campaign_dir="$(find "$WORKDIR/campaigns" -maxdepth 8 -type d -name "campaign_${campaign_num}" 2>/dev/null | head -1)"
        if [ -z "$campaign_dir" ]; then
            log_error "Campaign directory not found: campaign_${campaign_num}"
            ((total_errors++)) || true
            continue
        fi
        instances_base="${campaign_dir}/findings"
    fi

    if [ ! -d "$instances_base" ]; then
        log_error "Instance base not found: ${instances_base}"
        ((total_errors++)) || true
        continue
    fi

    log_info "  Found: ${instances_base}"

    classification_out="${CLASSIFICATION_DIR}/campaign_${campaign_num}"
    mkdir -p "$classification_out"

    campaign_instances=0

    for instance_dir in "$instances_base"/*/; do
        [ -d "$instance_dir" ] || continue
        instance_name="$(basename "$instance_dir")"

        crashes_dir="${instance_dir}/crashes"

        # Skip if no crashes/ subdirectory or empty
        if [ ! -d "$crashes_dir" ]; then
            log_warn "No crashes/ in ${instance_name}, skipping"
            ((total_skipped++)) || true
            continue
        fi

        # Count actual crash files (exclude README.txt and dotfiles)
        crash_count=$(find "$crashes_dir" -maxdepth 1 -type f ! -name 'README.txt' ! -name '.*' 2>/dev/null | wc -l)
        if [ "$crash_count" -eq 0 ]; then
            log_info "  ${instance_name}: no crash files, skipping"
            ((total_skipped++)) || true
            continue
        fi

        log_info "  Classifying instance: ${instance_name} ($crash_count crashes)"

        instance_out="${classification_out}/${instance_name}"
        mkdir -p "$instance_out"

        docker run --rm \
            -v "${crashes_dir}:/classification/input:ro" \
            -v "${instance_out}:/classification_out" \
            -e "INPUT_DIR=/classification/input" \
            -e "OUTPUT_DIR=/classification_out" \
            -e "PROGRAM_NAME=${PROGRAM_NAME}" \
            -e "PROGRAM_ARGS=${PROGRAM_ARGS:-}" \
            -e "TIMEOUT_EACH=${TIMEOUT_EACH:-10}" \
            "$CLASSIFICATION_IMAGE" \
            /magma/tools/pirate/scripts/start_classification.sh

        if [ -f "${instance_out}/classification.csv" ]; then
            log_info "  Results: ${instance_out}/"
        else
            log_warn "  No classification output for ${instance_name}"
        fi

        ((campaign_instances++)) || true
        ((total_instances++)) || true
    done

    log_success "Campaign ${campaign_num}: ${campaign_instances} instances classified"
    ((total_campaigns++)) || true
done

################################################################################
# Summary — aggregate per-instance summary.csv into one file
################################################################################
SUMMARY_FILE="${CLASSIFICATION_DIR}/summary.csv"
echo "campaign;bug;optimization;instance;patch_failed;regression;base_bug;fix_bug;no_crash;unknown;total" > "$SUMMARY_FILE"

for campaign_num in $CAMPAIGNS; do
    classification_out="${CLASSIFICATION_DIR}/campaign_${campaign_num}"
    [ -d "$classification_out" ] || continue

    for instance_summary in "$classification_out"/*/summary.csv; do
        [ -f "$instance_summary" ] || continue
        instance_name="$(basename "$(dirname "$instance_summary")")"
        # Read the data line (skip header)
        tail -1 "$instance_summary" | while IFS=';' read -r pf reg bb fb nc unk tot; do
            printf '%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n' \
                "$campaign_num" "$BUG" "$OPTIMIZATION" "$instance_name" \
                "$pf" "$reg" "$bb" "$fb" "$nc" "$unk" "$tot"
        done >> "$SUMMARY_FILE"
    done
done

log_success "=== Classification complete ==="
log_success "Campaigns: ${total_campaigns}, Instances: ${total_instances}, Skipped: ${total_skipped}, Errors: ${total_errors}"
log_success "Summary:   ${SUMMARY_FILE}"
log_success "Results:   ${CLASSIFICATION_DIR}/"