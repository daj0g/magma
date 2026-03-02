#!/bin/bash
set -e

##############################################################################
# run_replay.sh — Replay orchestrator for campaign queues
#
# Iterates over all AFL++ instances in one or more source campaigns,
# launches Docker containers with the patched image to replay each
# instance queue, and collects results into WORKDIR/replay/o<OPT>/campaign_<N>/.
#
# Source campaigns and replay image are decoupled: you can replay O2
# vulnerable queues against the O1 patched binary.
#
# Usage:
#   ./run_replay.sh [replayrc]
#
# Configuration is read from replayrc (default: ./replayrc).
#
# replayrc variables:
#   WORKDIR         Working directory (default: ./workdir)
#   TARGET_NAME     Target library (e.g. libpng)
#   BUG             Bug identifier (e.g. PNG006)
#   OPTIMIZATION    Patched binary optimization level (1/2/3)
#   PROGRAM_NAME    Harness binary name
#   PROGRAM_ARGS    Harness arguments (optional)
#   CAMPAIGNS       Space-separated campaign numbers or ranges
#                   (e.g. "315 316 317" or "315-320" or "315-318 400 500-502")
##############################################################################

PIRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PIRATE}/scripts/util.sh"

################################################################################
# Load configuration
################################################################################
RCFILE="${1:-${PIRATE}/replayrc}"
if [ ! -f "$RCFILE" ]; then
    log_error "Config file not found: $RCFILE"
    exit 1
fi
set -a
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
# Derive patched image name (CANARY_MODE=4)
################################################################################
CANARY_MODE=4
PATCHED_IMAGE="$(derive_image_name)"

WORKDIR="$(realpath "${WORKDIR:-./workdir}")"
REPLAY_DIR="${WORKDIR}/replay/${TARGET_NAME}/${BUG}/o${OPTIMIZATION}"

log_info "Patched image: ${PATCHED_IMAGE} (replay target)"
log_info "Output:        ${REPLAY_DIR}/"
log_info "Campaigns:     ${CAMPAIGNS}"
log_info "Program:       ${PROGRAM_NAME} ${PROGRAM_ARGS:-}"

################################################################################
# Verify image exists
################################################################################
if ! docker image inspect "$PATCHED_IMAGE" &>/dev/null; then
    log_error "Docker image not found: ${PATCHED_IMAGE}"
    log_error "Build the patched image first (CANARY_MODE=4)."
    exit 1
fi

################################################################################
# Main loop: iterate over campaigns and instances
################################################################################
total_campaigns=0
total_instances=0
total_errors=0

for campaign_num in $CAMPAIGNS; do
    campaign_dir="$(find "$WORKDIR/campaigns" -maxdepth 8 -type d -name "campaign_${campaign_num}" 2>/dev/null | head -1)"

    log_info "=== Campaign ${campaign_num} ==="

    if [ -z "$campaign_dir" ]; then
        log_error "Campaign directory not found: campaign_${campaign_num}"
        ((total_errors++)) || true
        continue
    fi

    findings_dir="${campaign_dir}/findings"
    if [ ! -d "$findings_dir" ]; then
        log_error "No findings/ in ${campaign_dir}"
        ((total_errors++)) || true
        continue
    fi

    log_info "  Found: ${campaign_dir}"

    replay_out="${REPLAY_DIR}/campaign_${campaign_num}"
    mkdir -p "$replay_out"

    campaign_instances=0

    for instance_dir in "$findings_dir"/*/; do
        [ -d "$instance_dir" ] || continue
        instance_name="$(basename "$instance_dir")"

        # Skip if no queue/ subdirectory
        if [ ! -d "${instance_dir}/queue" ]; then
            log_warn "No queue/ in ${instance_name}, skipping"
            continue
        fi

        # Detect QASAN instance
        qasan_flag=0
        if [ "$instance_name" = "qasan" ]; then
            qasan_flag=1
        fi

        log_info "  Replaying instance: ${instance_name} (QASAN=${qasan_flag})"

        docker run --rm \
            -v "${campaign_dir}:/magma_shared" \
            -e "INPUT_DIR=/magma_shared/findings/${instance_name}/queue" \
            -e "OUTPUT_DIR=/magma_shared/findings/${instance_name}/replay_o${OPTIMIZATION}" \
            -e "PROGRAM_NAME=${PROGRAM_NAME}" \
            -e "PROGRAM_ARGS=${PROGRAM_ARGS:-}" \
            -e "QASAN=${qasan_flag}" \
            "$PATCHED_IMAGE" \
            /magma/tools/pirate/scripts/start_replay.sh

        # Copy results to flat replay directory
        if [ -d "${instance_dir}/replay_o${OPTIMIZATION}" ]; then
            cp -r "${instance_dir}/replay_o${OPTIMIZATION}" "${replay_out}/${instance_name}"
            log_info "  Results copied to: ${replay_out}/${instance_name}"
        else
            log_warn "  No replay output for ${instance_name}"
        fi

        ((campaign_instances++)) || true
        ((total_instances++)) || true
    done

    log_success "Campaign ${campaign_num}: ${campaign_instances} instances replayed"
    ((total_campaigns++)) || true
done

################################################################################
# Summary — aggregate per-instance summary.csv into one file
################################################################################
SUMMARY_FILE="${REPLAY_DIR}/summary.csv"
echo "campaign;bug;optimization;instance;count;skipped;reached;triggered;crashed" > "$SUMMARY_FILE"

for campaign_num in $CAMPAIGNS; do
    replay_out="${REPLAY_DIR}/campaign_${campaign_num}"
    [ -d "$replay_out" ] || continue

    for instance_summary in "$replay_out"/*/summary.csv; do
        [ -f "$instance_summary" ] || continue
        instance_name="$(basename "$(dirname "$instance_summary")")"
        # Read the data line (skip header)
        tail -1 "$instance_summary" | while IFS=';' read -r count skipped reached triggered crashed; do
            printf '%s;%s;%s;%s;%s;%s;%s;%s;%s\n' \
                "$campaign_num" "$BUG" "$OPTIMIZATION" "$instance_name" \
                "$count" "$skipped" "$reached" "$triggered" "$crashed"
        done >> "$SUMMARY_FILE"
    done
done

log_success "=== Replay complete ==="
log_success "Campaigns: ${total_campaigns}, Instances: ${total_instances}, Errors: ${total_errors}"
log_success "Summary:   ${SUMMARY_FILE}"
log_success "Results:   ${REPLAY_DIR}/"
