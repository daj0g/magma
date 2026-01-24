################################################################################
# Utility functions
################################################################################
if [ -t 1 ] || [ -n "$FORCE_COLOR" ]; then
    # Colors enabled
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_RED="\033[1;31m"
    C_RESET="\033[0m"
else
    # Colors disabled (empty strings)
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_RESET=""
fi


log_info() {
    local logfile="${2:-/dev/null}"
    echo -e "${C_GREEN}[$(date '+%H:%M:%S')]${C_RESET} $1" | tee -a "$logfile"
}

log_warn() {
    local logfile="${2:-/dev/null}"
    echo -e "${C_YELLOW}[$(date '+%H:%M:%S')]${C_RESET} $1" | tee -a "$logfile"
}

log_error() {
    local logfile="${2:-/dev/null}"
    echo -e "${C_RED}[$(date '+%H:%M:%S')]${C_RESET} $1" | tee -a "$logfile"
}

log_trace() {
    for ((i=0; i<${#FUNCNAME[@]}; i++)); do
        local func="${FUNCNAME[$i]}"
        local line="${BASH_LINENO[$((i-1))]}"
        local file="${BASH_SOURCE[$i]}"

        echo -e "   at ${file}:${line} (function: $func)"
    done
}

################################################################################
# Execution Guard / Test Block
################################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Running utils.sh tests..."
    log_info "This message will be GREEN if run directly, plain text if piped."
    log_warn "This message will be YELLOW if run directly, plain text if piped."
    log_error "This message will be RED if run directly, plain text if piped."
fi