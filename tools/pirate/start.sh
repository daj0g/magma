#!/bin/bash
set +e

# This starts individual cross-compiled Docker containers for campaigns
#
# Pre-requirements
# - IMG_NAME_TARGET:  docker image name
# - env TARGET_NAME:  target name (from targets/)
# - env SHARED:       path to host-local volume where fuzzer findings are saved
#
# + env PROGRAM_NAME: harness name (name of binary artifact from $TARGET_build_cross.sh)
#                     (default: first dir in $TARGET/corpus/)
# + env PROGRAM_ARGS: harness launch arguments
#                     (default: )
# + env POLL:         time (in seconds) between polls of Magma monitor
#                     (default: 5)
# + env WORKERS:      How many "dumb" workers to run
#                     (default: 2)
# + env TIMEOUT:      time to run the campaign
#                     (default: 10min)
##############################################################################


if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -z "$1" ]; then
        set -- "./piraterc"
    fi

    # load the configuration file (piraterc)
    set -a
    source "$1"
    set +a
fi

source "${PIRATE}/scripts/util.sh"


################################################################################
# Configuration
################################################################################
PROGRAM_NAME="${PROGRAM_NAME:-$(basename -a ${TARGET}/corpus/*/ | head -1)}"
PROGRAM_ARGS="${PROGRAM_ARGS:-}"

POLL="${POLL:-5}"
TIMEOUT="${TIMEOUT:-5m}"
WORKERS="${WORKERS:-2}"
LOGSIZE=$(( 10 << 20 )) # 10 MiB


CAMPAIGN_ID="${IMG_NAME_TARGET:-unknown}/${PROGRAM_NAME}/$(date +%Y%m%d-%H%M%S)"
CAMPAIGN_DIR="${SHARED}/campagins/${CAMPAIGN_ID}"

# WARN: It is crucial to export MAGMA_STORAGE and set it to a value that is
#       NOT SHARED by multiple conatiners (e.g. via -v option)!
#       If it is set to a location that is shared by multiple Docker conatiners
#       (e.g. $SHARED), the `canaries.raw` file is shared across those
#       containers and thus across multple campaigns!
export MAGMA_STORAGE="${CAMPAIGN_DIR}/canaries.raw"

MONITOR="${CAMPAIGN_DIR}/monitor"
FINDINGS="${CAMPAIGN_DIR}/findings"
LOGDIR="${CAMPAIGN_DIR}/log"
MONITORLOG="${LOGDIR}/monitor.log"
FUZZERLOG="${LOGDIR}/fuzzer.log"

mkdir -p "$SHARED"
mkdir -p "$MONITOR"
mkdir -p "$FINDINGS"
mkdir -p "$LOGDIR"

# change working directory to somewhere accessible by the fuzzer and target
cd "$SHARED" || true

################################################################################
# Verification
################################################################################
if [ ! -f "${OUT}/$PROGRAM_NAME" ]; then
    log_error "Error: PROGRAM not found: ${OUT}/${PROGRAM_NAME}" "$FUZZERLOG"
    exit 1
fi

# Check harness architecture
log_info "Harness info:"
log_info "$(file "${OUT}/${PROGRAM_NAME}")" "$FUZZERLOG"


if [ ! -f "${FUZZER}/repo/afl-qemu-trace" ]; then
    log_error "Error: afl-qemu-trace not found ${FUZZER}/repo/"
    exit 1
fi

################################################################################
# Summary export/print
################################################################################

setup_summary() {
    cat << EOF | tee "${CAMPAIGN_DIR}/campaign_summary.txt"
===============================================================================
                                  SUMMARY
===============================================================================
Campaign:                       ${CAMPAIGN_ID}
Campaign directory:             ${CAMPAIGN_DIR}

Fuzzer:                         ${FUZZER_NAME}
Target:                         ${TARGET_NAME}
Program/Harness:                ${PROGRAM_NAME}
Precompiled Library Path:       ${PRECOMPILED_LIB:-N/A}
Optimization level:             -O${OPTIMIZATION}
Magma setup:                    ${MAGMA_BUILD_FLAGS}

Timeout:                        ${TIMEOUT}
Poll:                           ${POLL}

Input directory:                ${INPUT}
Log directory:                  ${LOGDIR}
Monitor Logfile:                ${MONITORLOG}
Fuzzer Logfile (main):          ${FUZZERLOG}

QEMU_LD_PREFIX:                 ${QEMU_LD_PREFIX}
LD_LIBRARY_PATH:                ${LD_LIBRARY_PATH}

====
Target Address:                 ${target_addr}
EOF
}

##############################################################################
# Cleanup
##############################################################################
cleanup() {
    log_info "Cleaning up..." "$FUZZERLOG"
    "${OUT}/monitor" --dump human "$MAGMA_STORAGE" > "${MONITOR}/results.txt"
    jobs -p | xargs -r kill 2>/dev/null || true
    log_success "Everything clean. Exit." "${FUZZERLOG}"
}
trap cleanup EXIT

##############################################################################
# Monitor process
##############################################################################

log_info "Starting canary monitor..." "$MONITORLOG"

# Initialize monitor state
rm -f "${MONITOR}/tmp"*

# Get starting counter
shopt -s nullglob
polls=("${MONITOR}"/*)
shopt -u nullglob
if [ ${#polls[@]} -eq 0 ]; then
    counter=0
else
    timestamps=($(sort -n < <(basename -a "${polls[@]}" 2>/dev/null) 2>/dev/null))
    last=${timestamps[-1]:-0}
    counter=$(( last + POLL ))
fi

# Monitor loop in background
(
    set +e
    while true; do
        "${OUT}/monitor" --dump row "$MAGMA_STORAGE" > "${MONITOR}/tmp"
        status=$?
        if [ $status -eq 0 ]; then
            mv "${MONITOR}/tmp" "${MONITOR}/$counter"
        else
            rm "${MONITOR}/tmp"
            log_warn "Monitor failed (exit=${status}) at counter=$counter" \
                "$MONITORLOG"
        fi
        counter=$(( counter + POLL ))
        sleep "$POLL"
    done
) &
MONITOR_PID=$!
log_success "Monitor successfully started (PID: ${MONITOR_PID})" "$MONITORLOG"

# monitor_exit() {
#     kill "$MONITOR_PID" 2>/dev/null
#     "${OUT}/monitor" --dump human > "${MONITOR}/result.txt"
#     log_info "Monitor stopped (PID: $MONITOR_PID)" "$MONITORLOG"
# }
# trap monitor_exit EXIT
# -> global cleanup


################################################################################
# Campaign
################################################################################
# Logging setup
mkdir -p "${LOGDIR}/cmplog"
mkdir -p "${LOGDIR}/compcov"
for id in $(seq 1 "$WORKERS"); do
    mkdir -p "${LOGDIR}/worker${id}"
done

# AFL++ variables
export AFL_SKIP_CPUFREQ=1
export AFL_NO_AFFINITY=1
export AFL_NO_UI=1
export AFL_MAP_SIZE=256000
# export AFL_DRIVER_DONT_DEFER=1
export AFL_INST_LIBS=1   # Make sure shared libraries are traced
export AFL_QEMU_DRIVER_NO_HOOK=1 # Use stdin, not hook

##############################################################
# Prepare Corpus / Inputs
##############################################################
log_info "Preparing Corpus..." "$FUZZERLOG"

MAGMA_CORPUS="${TARGET}/corpus/${CORPUS_NAME:-${PROGRAM_NAME}}"
PIRATE_CORPUS="${PIRATE}/input/${TARGET_NAME}${BUG:+/${BUG}}"

INPUT="${CAMPAIGN_DIR}/input/"
rm -rf "$INPUT" && mkdir -p "$INPUT"

# Copy original Magma seeds
if [ -n "$INCLUDE_POV" ]; then
    log_info "Copying PoV seeds into fuzzer input directory..." "$FUZZERLOG"
    cp "$PIRATE_CORPUS"/* "$INPUT" 2>/dev/null || true
fi
log_info "Copying original Magma seeds into fuzzer input directory..." "$FUZZERLOG"
cp "$MAGMA_CORPUS"/* "$INPUT" 2>/dev/null || true

# Minimise corpus (this also deletes PoVs!)
# NOTE: Old code, Variables worng!
# if ! ${FUZZER}/repo/afl-cmin -Q -i "$CORPUS" -o "$INPUT" \
#     -- "${OUT}/${PROGRAM_NAME}" ${PROGRAM_ARGS} 2>&1; then
#     log_warn "afl-cmin failed, using full corpus" "$FUZZERLOG"
#     INPUT="$CORPUS"
# fi

log_success "Corpus prepared successfully." "$FUZZERLOG"


############################################
# Extract and set library address for fuzzer
############################################
target_lib="${TARGET_NAME}.*[.]so.*"
AFL_QEMU_DEBUG_MAPS=1 \
    ${FUZZER}/repo/afl-qemu-trace \
    "${OUT}/${PROGRAM_NAME}" < /dev/null > "$CAMPAIGN_DIR"/trace 2>&1

target_addr=$(awk -v lib="$target_lib" '$2 ~ /..x./ && $6 ~ "magma_out/"lib {print $1; exit}' "$CAMPAIGN_DIR"/trace)

if [ "$(echo "$target_addr" | wc -w)" -ne 1 ]; then
    log_error "Library address could not be extracted successfully" "$FUZZERLOG"
    exit 1
fi

# Add 0x prefix to the memory locations
target_addr="0x${target_addr%-*}-0x${target_addr#*-}"

export AFL_QEMU_INST_RANGES=$target_addr
log_info "Target address set to ${target_addr}" "$FUZZERLOG"


setup_summary
############################################################
# Starting Campaign

# The setup follows the AFL++ recommendation
# - https://aflplus.plus/docs/fuzzing_binary-only_targets/
# - QASAN throws an error, idk why
############################################################
log_info "Campaign launched at $(date '+%F %R')" "$FUZZERLOG"
log_info "Starting AFL++ QEMU mode fuzzer..." "$FUZZERLOG"
AFL_ARGS=(
    "-Q"               # QEMU mode
    "-i" "$INPUT"      # Input directory
    "-o" "$FINDINGS"   # Output directory
    "-m" "none"        # No memory limit
)

log_info "Starting campaigns with $(( 2 + WORKERS )) instances ..." "$FUZZERLOG"

set -o pipefail
pids=()

# Run the main instance with CMPLOG (-d skip deterministic fuzzing)
AFL_COMPCOV_LEVEL=2 \
timeout "$TIMEOUT" \
    "${FUZZER}/repo/afl-fuzz" "${AFL_ARGS[@]}" \
    -M cmplog \
    -c 0 \
    -d \
    -- "${OUT}/${PROGRAM_NAME}" ${PROGRAM_ARGS} 2>&1 | \
    tee >(multilog n2 s${LOGSIZE} "${LOGDIR}/cmplog" 2>/dev/null) &
pids+=($!)

# Run second instance with CompCov/LAF
AFL_PRELOAD="${FUZZER}/repo/libcmpcov.so" \
AFL_COMPCOV_LEVEL=2 \
timeout "$TIMEOUT" \
    "${FUZZER}/repo/afl-fuzz" "${AFL_ARGS[@]}" \
    -S compcov \
    -- "${OUT}/${PROGRAM_NAME}" ${PROGRAM_ARGS} 2>&1 | \
    tee >(multilog n4 s${LOGSIZE} "${LOGDIR}/compcov" 2>/dev/null) &
pids+=($!)

# Run "dumb" workers (or as many as I want >=0)
for id in $(seq 1 "$WORKERS"); do
    timeout "$TIMEOUT" \
        "${FUZZER}/repo/afl-fuzz" "${AFL_ARGS[@]}" \
        -S "worker${id}" \
        -- "${OUT}/${PROGRAM_NAME}" ${PROGRAM_ARGS} 2>&1 | \
        tee >(multilog n4 s${LOGSIZE} "$LOGDIR/worker${id}" 2>/dev/null) &
    pids+=($!)
done

log_info "Campaign running with PIDs ${pids[*]}. Waiting for timeouts ..." \
    "$FUZZERLOG"


###################
# Status handling
###################
FINAL_STATUS=0
TIMEOUT_COUNT=0
ERROR_COUNT=0

for pid in "${pids[@]}"; do
    wait "$pid"
    status=$?

    if [ $status -eq 124 ]; then
        ((TIMEOUT_COUNT++))
    elif [ $status -ne 0 ]; then
        log_error "Process ${pid} failed with status ${status}" "$FUZZERLOG"
        ((ERROR_COUNT++))
        FINAL_STATUS=$status
    fi
done

if [ $ERROR_COUNT -gt 0 ]; then
    log_error \
        "Campaign FAILED: $ERROR_COUNT instance(s) crashed / failed to start." \
        "$FUZZERLOG"
    # Propagate the last error code found
    exit $FINAL_STATUS
elif [ $TIMEOUT_COUNT -gt 0 ]; then
    log_success "Campaign completed successfully" "$FUZZERLOG"
    log_success "(Timeout reached for $TIMEOUT_COUNT instances)." "$FUZZERLOG"
    exit 124
else
    log_warn "Campaign ended with status 0 (Unexpected for timeout-driven runs)." \
        "$FUZZERLOG"
    exit 0
fi