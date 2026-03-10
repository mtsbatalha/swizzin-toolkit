#!/usr/bin/env bash
# lib/tune/tune.sh — Tuning orchestrator
# Loads all tune modules and dispatches to selected targets.
# Called by toolkit.sh; do not call directly.

[[ -n "${_TOOLKIT_TUNE_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_LOADED=1

# Resolve script dir so we can source sibling files regardless of CWD
_TUNE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all tune modules
# shellcheck source=lib/tune/kernel.sh
source "${_TUNE_DIR}/kernel.sh"
# shellcheck source=lib/tune/network.sh
source "${_TUNE_DIR}/network.sh"
# shellcheck source=lib/tune/disk.sh
source "${_TUNE_DIR}/disk.sh"
# shellcheck source=lib/tune/rtorrent.sh
source "${_TUNE_DIR}/rtorrent.sh"
# shellcheck source=lib/tune/qbittorrent.sh
source "${_TUNE_DIR}/qbittorrent.sh"
# shellcheck source=lib/tune/deluge.sh
source "${_TUNE_DIR}/deluge.sh"
# shellcheck source=lib/tune/transmission.sh
source "${_TUNE_DIR}/transmission.sh"
# shellcheck source=lib/tune/plex.sh
source "${_TUNE_DIR}/plex.sh"

# Valid tune targets
TUNE_TARGETS_ALL=(kernel network disk rtorrent qbittorrent deluge transmission plex)

# ─── Main dispatcher ─────────────────────────────────────────────────────────

# run_tune TARGETS...
# TARGETS: comma-separated or space-separated list of targets, or "all"
run_tune() {
    local targets_input="${1:-all}"
    local -a targets

    if [[ "$targets_input" == "all" ]]; then
        targets=("${TUNE_TARGETS_ALL[@]}")
    else
        # Accept comma or space separated
        IFS=', ' read -r -a targets <<< "$targets_input"
    fi

    require_root

    # Auto-detect hardware (or use overrides set by caller)
    if [[ -z "${DETECTED_RAM:-}" ]]; then
        echo_progress_start "Detecting hardware..."
        detect_all_hardware
        echo_progress_done
    fi

    display_hardware_info

    # Create a tuning backup session for rollback
    local session_dir
    session_dir="${TOOLKIT_TUNE_BACKUP_ROOT}/$(make_timestamp)"
    if [[ "${DRY_RUN:-false}" != true ]]; then
        mkdir -p "$session_dir"
        _save_tune_session_info "$session_dir" "${targets[*]}"
    fi

    # Run each requested target
    for target in "${targets[@]}"; do
        case "$target" in
            kernel)       tune_kernel      ;;
            network)      tune_network     ;;
            disk)         tune_disk        ;;
            rtorrent)     tune_rtorrent    ;;
            qbittorrent)  tune_qbittorrent ;;
            deluge)       tune_deluge      ;;
            transmission) tune_transmission;;
            plex)         tune_plex        ;;
            *)
                echo_warn "Unknown tune target: ${target}"
                echo_info "Valid targets: ${TUNE_TARGETS_ALL[*]}"
                ;;
        esac
    done

    if [[ "${DRY_RUN:-false}" != true ]]; then
        echo_success "Tuning complete! Backup saved to: ${session_dir}"
        echo_info "To rollback: toolkit rollback --timestamp $(basename "$session_dir")"
    fi
}

# ─── Rollback ────────────────────────────────────────────────────────────────

# run_rollback [--timestamp TS]
run_rollback() {
    local timestamp="${1:-}"

    if [[ -z "$timestamp" ]]; then
        # Use most recent session
        timestamp=$(ls -1t "${TOOLKIT_TUNE_BACKUP_ROOT}" 2>/dev/null | head -1)
    fi

    if [[ -z "$timestamp" ]]; then
        echo_error "No tuning backup sessions found in ${TOOLKIT_TUNE_BACKUP_ROOT}"
        return 1
    fi

    local session_dir="${TOOLKIT_TUNE_BACKUP_ROOT}/${timestamp}"
    if [[ ! -d "$session_dir" ]]; then
        echo_error "Backup session not found: ${session_dir}"
        return 1
    fi

    echo_header "Rollback — Session: ${timestamp}"
    require_root

    # Read which targets were tuned
    local targets_file="${session_dir}/targets.txt"
    local targets_str=""
    [[ -f "$targets_file" ]] && targets_str=$(cat "$targets_file")

    echo_info "Restoring from session: ${session_dir}"

    # Rollback kernel/network sysctl
    if echo "$targets_str" | grep -qE 'kernel|network'; then
        rollback_kernel "$session_dir"
    fi

    # Rollback disk
    if echo "$targets_str" | grep -q 'disk'; then
        rollback_disk
    fi

    # Rollback plex
    if echo "$targets_str" | grep -q 'plex'; then
        rollback_plex
    fi

    # App configs are restored via backup module
    # They were backed up with backup_file() which creates .bak.TIMESTAMP copies
    echo_info "For individual app config rollback, use: toolkit restore"
    echo_success "Rollback complete"
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

_save_tune_session_info() {
    local session_dir="$1"
    local targets="$2"

    echo "$targets" > "${session_dir}/targets.txt"

    # Snapshot current sysctl state
    sysctl -a 2>/dev/null > "${session_dir}/sysctl_before.txt" || true

    # Copy existing toolkit sysctl file if present
    if [[ -f "${TOOLKIT_SYSCTL_FILE}" ]]; then
        cp "${TOOLKIT_SYSCTL_FILE}" "${session_dir}/sysctl.conf.bak" 2>/dev/null || true
    fi

    # Save hardware info
    {
        echo "timestamp=$(make_timestamp)"
        echo "profile=$(get_effective_profile)"
        echo "disk=$(get_effective_disk)"
        echo "ram=$(get_effective_ram)"
        echo "cpu=$(get_effective_cpu)"
        echo "net_speed=$(get_effective_net_speed)"
    } > "${session_dir}/hardware.txt"
}
