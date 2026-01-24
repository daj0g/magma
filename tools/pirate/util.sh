################################################################################
# Utility functions
################################################################################
# Colors enabled
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_BLUE="\033[0;34m"
C_RED="\033[0;31m"
C_RESET="\033[0m"

log_info() {
    local msg="$1"
    local logfile="${2:-/dev/null}"

    # Logfile
    echo "[$(date '+%H:%M:%S')] [INFO]  $msg" >> $logfile
    # Terminal
    echo -e "${C_GREEN}[$(date '+%H:%M:%S')]${C_RESET} $msg"
}

log_warn() {
    local msg="$1"
    local logfile="${2:-/dev/null}"

    # Logfile
    echo "[$(date '+%H:%M:%S')] [WARN]  $msg" >> $logfile
    # Terminal
    echo -e "${C_YELLOW}[$(date '+%H:%M:%S')]${C_RESET} $msg"
}

log_error() {
    local msg="$1"
    local logfile="${2:-/dev/null}"

    # Logfile
    echo "[$(date '+%H:%M:%S')] [ERROR] $msg" >> $logfile
    # Terminal
    echo -e "${C_RED}[$(date '+%H:%M:%S')]${C_RESET} $msg"
}

log_docker() {
    local msg="$1"
    local logfile="${2:-/dev/null}"

    # Logfile
    echo "          [DOCKER]  > $msg" >> "$logfile"
    # Terminal
    echo -e "${C_BLUE}  [DOCKER]  >${C_RESET} $msg"
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