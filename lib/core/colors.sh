#!/usr/bin/env bash
# lib/core/colors.sh — Standalone terminal color and echo utilities
# Works without swizzin installed. If swizzin globals are sourced first,
# those echo_* functions take precedence (they are compatible).

# Avoid re-sourcing
[[ -n "${_TOOLKIT_COLORS_LOADED:-}" ]] && return 0
_TOOLKIT_COLORS_LOADED=1

# ─── ANSI escape codes ────────────────────────────────────────────────────────
_C_RESET='\033[0m'
_C_BOLD='\033[1m'
_C_DIM='\033[2m'
_C_RED='\033[0;31m'
_C_GREEN='\033[0;32m'
_C_YELLOW='\033[0;33m'
_C_BLUE='\033[0;34m'
_C_CYAN='\033[0;36m'
_C_WHITE='\033[0;37m'
_C_BRED='\033[1;31m'
_C_BGREEN='\033[1;32m'
_C_BYELLOW='\033[1;33m'
_C_BBLUE='\033[1;34m'
_C_BCYAN='\033[1;36m'
_C_BWHITE='\033[1;37m'

# Disable colors when not a tty or when NO_COLOR is set
_colors_enabled() {
    [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]
}

# ─── Internal formatter ───────────────────────────────────────────────────────
# Usage: _colorprint COLOR LABEL MESSAGE
_colorprint() {
    local color="$1" label="$2"
    shift 2
    local msg="$*"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"

    if _colors_enabled; then
        printf "%b[%s]%b %s\n" "${color}" "${label}" "${_C_RESET}" "${msg}"
    else
        printf "[%s] %s\n" "${label}" "${msg}"
    fi

    # Append to log file if configured and writable
    if [[ -n "${TOOLKIT_LOG:-}" ]] && [[ "${TOOLKIT_LOG}" != "/dev/null" ]]; then
        printf "[%s] [%s] %s\n" "${timestamp}" "${label}" "${msg}" >> "${TOOLKIT_LOG}" 2>/dev/null || true
    fi
}

# ─── Public echo functions ────────────────────────────────────────────────────

# echo_info: general informational message (white)
echo_info() {
    _colorprint "${_C_BWHITE}" "INFO" "$*"
}

# echo_success: operation completed successfully (green)
echo_success() {
    _colorprint "${_C_BGREEN}" "OK" "$*"
}

# echo_warn: non-fatal warning (yellow, bell)
echo_warn() {
    printf '\a' 2>/dev/null || true
    _colorprint "${_C_BYELLOW}" "WARN" "$*" >&2
}

# echo_error: fatal or serious error (red, bell)
echo_error() {
    printf '\a' 2>/dev/null || true
    _colorprint "${_C_BRED}" "ERROR" "$*" >&2
}

# echo_progress_start: beginning of an operation (dim, no newline style)
echo_progress_start() {
    if _colors_enabled; then
        printf "%b[....] %s%b\n" "${_C_DIM}" "$*" "${_C_RESET}"
    else
        printf "[....] %s\n" "$*"
    fi
}

# echo_progress_done: end of operation (green checkmark)
echo_progress_done() {
    if _colors_enabled; then
        printf "%b[ OK ] %s%b\n" "${_C_BGREEN}" "${*:-Done}" "${_C_RESET}"
    else
        printf "[ OK ] %s\n" "${*:-Done}"
    fi
}

# echo_step: numbered step (blue)
echo_step() {
    _colorprint "${_C_BBLUE}" "STEP" "$*"
}

# echo_query: print a prompt without trailing newline (blue, no label)
echo_query() {
    if _colors_enabled; then
        printf "%b%s%b " "${_C_BCYAN}" "$*" "${_C_RESET}"
    else
        printf "%s " "$*"
    fi
}

# echo_header: section header (bold cyan, padded)
echo_header() {
    local title="$*"
    local line
    line="$(printf '%*s' "${#title}" '' | tr ' ' '─')"
    if _colors_enabled; then
        printf "\n%b%s%b\n%b%s%b\n\n" "${_C_BCYAN}" "${title}" "${_C_RESET}" "${_C_DIM}" "${line}" "${_C_RESET}"
    else
        printf "\n%s\n%s\n\n" "${title}" "${line}"
    fi
}

# echo_dry_run: show a would-be action in dry-run mode (cyan)
echo_dry_run() {
    _colorprint "${_C_CYAN}" "DRY" "$*"
}
