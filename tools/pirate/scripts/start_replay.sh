#!/bin/bash
set +e

##############################################################################
# start_replay.sh — Queue Replay
#
# - Rkeplays a single AFL++ instance queue against a patched binary.
# - For each input, captures canary stdout (reached/triggered) AND exit status
#   (crash detection).
# - Outputs a per-input CSV for later aggregation.
#
# Runs inside the patched campaign image (CANARY_MODE=4).
# The patched library is already in $OUT (/magma_out/).
#
# Environment variables:
# - INPUT_DIR      Single queue directory to replay (required)
#                  e.g. findings/cmplog/queue/
# + OUTPUT_DIR     Replay output directory
#                  (default: INPUT_DIR/../replay, e.g. findings/cmplog/replay/)
#                  Layout:
#                    OUTPUT_DIR/replay.csv       — per-input results
#                    OUTPUT_DIR/crashes/         — copies of crashing inputs
#                    OUTPUT_DIR/stderr/          — per-input stderr (if SAVE_STDERR=1)
# + PROGRAM_NAME   Harness binary name (must exist in $OUT)
# + PROGRAM_ARGS   Harness argumentsr (optional)
# + TIMEOUT_EACH   Per-input timeout in seconds (default: 10)
# + LIB_DIR        Patched library directory (default: ${OUT})
# + QASAN          Set to 1 to enable QASAN during replay.
#                  Should match the fuzzing campaign setup
#                  (default: 0 = disabled)
# + SAVE_STDERR    Set to 1 to save per-input stderr logs to OUTPUT_DIR/stderr/.
#                  Especiall useful with QASAN=1 to capture QASAN diagnostics.
#                  (default: 0 = stderr discarded)
################################################################################

source "${PIRATE}/scripts/util.sh"

INPUT_DIR="${INPUT_DIR:?INPUT_DIR must be set (single queue directory)}"
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$INPUT_DIR")/replay}"
TIMEOUT_EACH="${TIMEOUT_EACH:-10}"
HARNESS="${OUT}/${PROGRAM_NAME}"
LIB_DIR="${LIB_DIR:-${OUT}}"
QASAN="${QASAN:-0}"
SAVE_STDERR="${SAVE_STDERR:-0}"

OUTPUT_CSV="$OUTPUT_DIR/replay.csv"
CRASH_DIR="$OUTPUT_DIR/crashes"
STDERR_DIR="$OUTPUT_DIR/stderr"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

################################################################################
# Validation
################################################################################
if [ ! -f "$HARNESS" ]; then
    log_error "Harness not found: $HARNESS"
    exit 1
fi
if [ ! -d "$INPUT_DIR" ]; then
    log_error "Input directory not found: $INPUT_DIR"
    exit 1
fi
if [ ! -d "$LIB_DIR" ]; then
    log_error "Library directory not found: $LIB_DIR"
    exit 1
fi

if [ -d "$OUTPUT_DIR" ]; then
    log_warn "Output directory already exists, wiping: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR" "$CRASH_DIR"
[ "$SAVE_STDERR" = "1" ] && mkdir -p "$STDERR_DIR"

log_info "Harness:      $HARNESS"
log_info "Library dir:  $LIB_DIR"
log_info "Input dir:    $INPUT_DIR"
log_info "Output dir:   $OUTPUT_DIR"
log_info "Timeout/run:  ${TIMEOUT_EACH}s"
log_info "QASAN:        $([ "$QASAN" = "1" ] && echo enabled || echo disabled)"
log_info "Save stderr:  $([ "$SAVE_STDERR" = "1" ] && echo yes || echo no)"

################################################################################
# Replay single file:
# (captures stdout (for canary parsing) and exit code)
################################################################################
# Build env array
REPLAY_ENV=(
    QEMU_LD_PREFIX="$QEMU_LD_PREFIX"
    LD_LIBRARY_PATH="$LIB_DIR"
    AFL_QEMU_DRIVER_NO_HOOK=1
)
[ "$QASAN" = "1" ] && REPLAY_ENV+=( AFL_USE_QASAN=1 )

replay_file() {
    local input_file="$1"

    case "${PROGRAM_ARGS:-}" in
    *@@*) # file input
        local actual_args="${PROGRAM_ARGS/@@/$input_file}"
        (
            cd "$TMPDIR_WORK"
            timeout "$TIMEOUT_EACH" \
                env "${REPLAY_ENV[@]}" \
                "$FUZZER/repo/afl-qemu-trace" "$HARNESS" $actual_args
        )
        ;;
    *) # stdin
        timeout "$TIMEOUT_EACH" \
            env "${REPLAY_ENV[@]}" \
            "$FUZZER/repo/afl-qemu-trace" "$HARNESS" \
            < "$input_file"
        ;;
    esac
}

################################################################################
# Canary parser
# Sets: reached (count), triggered (count), bug (name or empty)
################################################################################
parse_canary() {
    local stdout="$1"
    reached=0
    triggered=0
    bug=""

    local prev_reached=0
    while IFS= read -r line; do
        if [ "$line" = "REACHED " ]; then
            ((reached++))
            prev_reached=1
        elif [ "$prev_reached" -eq 1 ] && [ -n "$line" ]; then
            ((triggered++))
            bug="$line"
            prev_reached=0
        else
            prev_reached=0
        fi
    done <<< "$stdout"
}

################################################################################
# Main loop
################################################################################
echo "input;reached;triggered;bug;crashed;exit_code" > "$OUTPUT_CSV"

# Initalise counters
count=0
skipped=0
total_reached=0
total_triggered=0
total_crashed=0

while IFS= read -r -d '' f; do
    name="$(basename "$f")"

    # Skip AFL++ README.txt
    case "$name" in
        README.txt|.*) ((skipped++)); continue ;;
    esac

    # Run against patched binary, capture stdout + exit code
    if [ "$SAVE_STDERR" = "1" ]; then
        stdout=$(replay_file "$f" 2>"$STDERR_DIR/$name.stderr")
    else
        stdout=$(replay_file "$f" 2>/dev/null)
    fi
    exit_code=$?

    # Parse canary output
    parse_canary "$stdout"

    # Determine crash status (timeout=124 is not a crash)
    if [ "$exit_code" -gt 0 ]; then
        crashed=1
        cp "$f" "$CRASH_DIR/"
    else
        crashed=0
    fi

    # Write CSV row
    printf '%s;%s;%s;%s;%s;%s\n' \
        "$name" "$reached" "$triggered" "$bug" "$crashed" "$exit_code" \
        >> "$OUTPUT_CSV"

    # Update counters
    ((count++))
    ((total_reached += reached))     || true  # true is needed because ((0)) returns exit code 1 => set +e!
    ((total_triggered += triggered)) || true
    ((total_crashed += crashed))     || true

    log_info "[$count] $name: reached=$reached triggered=$triggered bug=${bug:-(none)} crashed=$crashed exit=$exit_code"

done < <(find "$INPUT_DIR" -maxdepth 1 -type f -print0 | sort -z)

################################################################################
# Summary
################################################################################
log_success "Replay complete: $count inputs processed, $skipped skipped."
log_success "  Reached:   $total_reached / $count"
log_success "  Triggered: $total_triggered / $count"
log_success "  Crashed:   $total_crashed / $count"
log_success "Results: $OUTPUT_CSV"

# Write summary file
SUMMARY_FILE="$OUTPUT_DIR/summary.csv"
echo "count;skipped;reached;triggered;crashed" > "$SUMMARY_FILE"
printf '%s;%s;%s;%s;%s\n' \
    "$count" "$skipped" "$total_reached" "$total_triggered" "$total_crashed" \
    >> "$SUMMARY_FILE"