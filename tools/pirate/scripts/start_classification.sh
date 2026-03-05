#!/bin/bash
set +e

##############################################################################
# start_classification.sh — Replay crash/queue inputs against all three library
#                   variants and classify each input using the differential
#                   crash matrix.
#
# Runs inside the classification Docker image built by classification.Dockerfile.
#
# Environment variables (set via docker run -e):
#   INPUT_DIR     Directory of inputs to replay (crashes or queue folder)
#   OUTPUT_DIR    Output directory for classification results
#                 (default: /magma_shared/classification)
#                 Layout:
#                   OUTPUT_DIR/classification.csv   — per-input results
#                   OUTPUT_DIR/summary.csv  — classification counts
#   PROGRAM_NAME  Harness binary name (must exist in $OUT)
#   PROGRAM_ARGS  Harness arguments; use @@ as file placeholder (optional)
#   TIMEOUT_EACH  Timeout per replay run in seconds (default: 10)
#
# Classification matrix:
#   patched=crash,  vulnerable=crash,     oracle=no_crash        -> patch_failed
#   patched=crash,  vulnerable=no_crash,  oracle=no_crash        -> regression
#   patched=crash,  vulnerable=crash,     oracle=crash           -> base_bug
#   patched=crash,  vulnerable=no_crash,  oracle=crash           -> fix_bug
#   patched=no_crash                                             -> no_crash
##############################################################################

source "${PIRATE}/scripts/util.sh"

INPUT_DIR="${INPUT_DIR:-/classification/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/magma_shared/classification}"
TIMEOUT_EACH="${TIMEOUT_EACH:-10}"
HARNESS="${OUT}/${PROGRAM_NAME}"

OUTPUT_CSV="$OUTPUT_DIR/classification.csv"
SUMMARY_FILE="$OUTPUT_DIR/summary.csv"

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

if [ -d "$OUTPUT_DIR" ]; then
    log_warn "Output directory already exists, wiping: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

log_info "Harness:      $HARNESS"
log_info "Input dir:    $INPUT_DIR"
log_info "Output dir:   $OUTPUT_DIR"
log_info "Timeout/run:  ${TIMEOUT_EACH}s"

################################################################################
# Replay helper
################################################################################
# Run the harness against a single input file with the given library directory.
# Returns the exit code of the harness (non-zero = crash).
run_variant() {
    local lib_dir="$1"
    local input_file="$2"

    case "${PROGRAM_ARGS:-}" in
    *@@*)
        # File-based harness (e.g. tiffcp): replace @@ with the input path
        local actual_args="${PROGRAM_ARGS/@@/$input_file}"
        # shellcheck disable=SC2086  # intentional word-splitting of args
        (
            cd "$TMPDIR_WORK" || exit
            timeout "$TIMEOUT_EACH" \
                env QEMU_LD_PREFIX="$QEMU_LD_PREFIX" \
                    LD_LIBRARY_PATH="$lib_dir" \
                    AFL_QEMU_DRIVER_NO_HOOK=1 \
                "$FUZZER/repo/afl-qemu-trace" "$HARNESS" $actual_args \
                > /dev/null 2>&1
        )
        ;;
    *)
        # Stdin-based harness (e.g. libpng_read_fuzzer)
        timeout "$TIMEOUT_EACH" \
            env QEMU_LD_PREFIX="$QEMU_LD_PREFIX" \
                LD_LIBRARY_PATH="$lib_dir" \
                AFL_QEMU_DRIVER_NO_HOOK=1 \
            "$FUZZER/repo/afl-qemu-trace" "$HARNESS" \
            < "$input_file" > /dev/null 2>&1
        ;;
    esac
    echo $?
}

################################################################################
# Classification
################################################################################
classify() {
    local p_exit="$1"
    local v_exit="$2"
    local o_exit="$3"

    local pc vc oc
    pc=$([ "$p_exit" -ne 0 ] && echo 1 || echo 0)
    vc=$([ "$v_exit" -ne 0 ] && echo 1 || echo 0)
    oc=$([ "$o_exit" -ne 0 ] && echo 1 || echo 0)

    if   [ "$pc" -eq 1 ] && [ "$vc" -eq 1 ] && [ "$oc" -eq 0 ]; then echo "patch_failed"
    elif [ "$pc" -eq 1 ] && [ "$vc" -eq 0 ] && [ "$oc" -eq 0 ]; then echo "regression"
    elif [ "$pc" -eq 1 ] && [ "$vc" -eq 1 ] && [ "$oc" -eq 1 ]; then echo "base_bug"
    elif [ "$pc" -eq 1 ] && [ "$vc" -eq 0 ] && [ "$oc" -eq 1 ]; then echo "fix_bug"
    elif [ "$pc" -eq 0 ];                                        then echo "no_crash"
    else                                                        echo "unknown"
    fi
}

################################################################################
# Main loop
################################################################################
echo "input;patched_exit;vulnerable_exit;oracle_exit;classification" > "$OUTPUT_CSV"

count=0
skipped=0
cnt_patch_failed=0
cnt_regression=0
cnt_base_bug=0
cnt_fix_bug=0
cnt_no_crash=0
cnt_unknown=0

while IFS= read -r -d '' f; do
    name="$(basename "$f")"

    # Skip AFL++ metadata files
    case "$name" in
        README.txt|.*) ((skipped++)); continue ;;
    esac

    p_exit=$(run_variant /classification/patched    "$f")
    v_exit=$(run_variant /classification/vulnerable "$f")
    o_exit=$(run_variant /classification/oracle     "$f")

    class=$(classify "$p_exit" "$v_exit" "$o_exit")

    printf '%s;%s;%s;%s;%s\n' \
        "$name" "$p_exit" "$v_exit" "$o_exit" "$class" \
        >> "$OUTPUT_CSV"

    # Update classification counters
    case "$class" in
        patch_failed) ((cnt_patch_failed++)) ;;
        regression)   ((cnt_regression++))   ;;
        base_bug)     ((cnt_base_bug++))     ;;
        fix_bug)      ((cnt_fix_bug++))      ;;
        no_crash)     ((cnt_no_crash++))     ;;
        *)            ((cnt_unknown++))      ;;
    esac

    log_info "[$((count+1))] $name: patched=$p_exit vuln=$v_exit oracle=$o_exit → $class"
    ((count++))

done < <(find "$INPUT_DIR" -maxdepth 1 -type f -print0 | sort -z)

################################################################################
# Summary
################################################################################
log_success "Classification complete: $count inputs classified, $skipped skipped."
log_success "  patch_failed: $cnt_patch_failed"
log_success "  regression:   $cnt_regression"
log_success "  base_bug:     $cnt_base_bug"
log_success "  fix_bug:      $cnt_fix_bug"
log_success "  no_crash:     $cnt_no_crash"
log_success "  unknown:      $cnt_unknown"
log_success "Results: $OUTPUT_CSV"

echo "patch_failed;regression;base_bug;fix_bug;no_crash;unknown;total" > "$SUMMARY_FILE"
printf '%s;%s;%s;%s;%s;%s;%s\n' \
    "$cnt_patch_failed" "$cnt_regression" "$cnt_base_bug" "$cnt_fix_bug" \
    "$cnt_no_crash" "$cnt_unknown" "$count" \
    >> "$SUMMARY_FILE"