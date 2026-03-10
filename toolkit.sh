#!/usr/bin/env bash
# toolkit.sh — swizzin-toolkit main CLI entry point
#
# Usage:
#   toolkit [subcommand] [options]
#
# Subcommands:
#   tune    [--auto|--manual] [--dry-run] [--yes] [--target TARGET[,TARGET...]]
#           [--profile light|medium|heavy] [--disk-type NVME|SSD|HDD]
#           [--ram GB] [--net-speed Mbps]
#   backup  [--target all|rtorrent|qbittorrent|deluge|transmission|plex]
#           [--user USER|--all-users]
#   restore [--file ARCHIVE] [--target APP] [--user USER]
#   list    [--app APP]
#   rollback [--timestamp TS]
#   status
#   help
#
# With no subcommand, opens the interactive menu.
#
# License: GPL-3.0

set -euo pipefail

# ─── Resolve toolkit root ────────────────────────────────────────────────────

_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
TOOLKIT_ROOT="$(cd "$(dirname "$_self")" && pwd)"
unset _self
export TOOLKIT_ROOT

# ─── Load configuration ──────────────────────────────────────────────────────

# shellcheck source=conf/defaults.conf
source "${TOOLKIT_ROOT}/conf/defaults.conf"

# ─── Load core libraries ─────────────────────────────────────────────────────

# shellcheck source=lib/core/colors.sh
source "${TOOLKIT_ROOT}/lib/core/colors.sh"
# shellcheck source=lib/core/hardware.sh
source "${TOOLKIT_ROOT}/lib/core/hardware.sh"
# shellcheck source=lib/core/swizzin.sh
source "${TOOLKIT_ROOT}/lib/core/swizzin.sh"
# shellcheck source=lib/core/utils.sh
source "${TOOLKIT_ROOT}/lib/core/utils.sh"

# ─── Optionally load swizzin functions ───────────────────────────────────────
# After loading, re-source colors.sh to ensure our echo_* functions take
# precedence over any swizzin globals that may redefine them.

load_swizzin_functions 2>/dev/null || true
unset _TOOLKIT_COLORS_LOADED
source "${TOOLKIT_ROOT}/lib/core/colors.sh"

# ─── Load modules ────────────────────────────────────────────────────────────

# shellcheck source=lib/tune/tune.sh
source "${TOOLKIT_ROOT}/lib/tune/tune.sh"
# shellcheck source=lib/backup/engine.sh
source "${TOOLKIT_ROOT}/lib/backup/engine.sh"
# shellcheck source=lib/ui/menu.sh
source "${TOOLKIT_ROOT}/lib/ui/menu.sh"

# ─── Global state ────────────────────────────────────────────────────────────

DRY_RUN=false
CONFIRM_ALL=false
export DRY_RUN CONFIRM_ALL

# ─── Argument parsing ────────────────────────────────────────────────────────

main() {
    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        tune)     _cmd_tune    "$@" ;;
        backup)   _cmd_backup  "$@" ;;
        restore)  _cmd_restore "$@" ;;
        list)     _cmd_list    "$@" ;;
        rollback) _cmd_rollback "$@" ;;
        status)   _cmd_status  "$@" ;;
        help|--help|-h) _show_help ;;
        "")       run_main_menu ;;
        *)
            echo_error "Unknown subcommand: ${subcommand}"
            _show_help
            exit 1
            ;;
    esac
}

# ─── Subcommand handlers ─────────────────────────────────────────────────────

_cmd_tune() {
    local targets="all"
    local mode="auto"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)     mode="auto";  shift ;;
            --manual)   mode="manual"; shift ;;
            --dry-run)  DRY_RUN=true; export DRY_RUN; shift ;;
            --yes|-y)   CONFIRM_ALL=true; export CONFIRM_ALL; shift ;;
            --target)   targets="$2"; shift 2 ;;
            --profile)  export OVERRIDE_PROFILE="$2"; shift 2 ;;
            --disk-type) export OVERRIDE_DISK="$2"; shift 2 ;;
            --ram)      export OVERRIDE_RAM="$2"; shift 2 ;;
            --net-speed) export OVERRIDE_NET_SPEED="$2"; shift 2 ;;
            *) echo_warn "Unknown option: $1"; shift ;;
        esac
    done

    if [[ "$mode" == "manual" ]]; then
        # For non-interactive manual mode, check if overrides were provided via flags
        # If not (running as CLI without whiptail), prompt for values
        if [[ -z "${OVERRIDE_PROFILE:-}" ]] && [[ -z "${OVERRIDE_DISK:-}" ]]; then
            _manual_override_cli
        fi
    else
        # Auto-detect if not already done
        [[ -z "${DETECTED_RAM:-}" ]] && detect_all_hardware
    fi

    run_tune "$targets"
}

_manual_override_cli() {
    detect_all_hardware
    echo_header "Manual Hardware Override"
    printf "Current detections:\n"
    printf "  RAM: %s GB | Disk: %s | Net: %s Mbps | Profile: %s\n\n" \
        "$(get_effective_ram)" "$(get_effective_disk)" \
        "$(get_effective_net_speed)" "$(get_effective_profile)"

    echo_query "Profile [light/medium/heavy] (Enter to keep '$(get_effective_profile)'):"
    local v; read -r v
    [[ -n "$v" ]] && export OVERRIDE_PROFILE="$v"

    echo_query "Disk type [NVME/SSD/HDD] (Enter to keep '$(get_effective_disk)'):"
    read -r v; [[ -n "$v" ]] && export OVERRIDE_DISK="$v"

    echo_query "Network speed in Mbps (Enter to keep '$(get_effective_net_speed)'):"
    read -r v; [[ -n "$v" ]] && export OVERRIDE_NET_SPEED="$v"

    echo_query "RAM in GB (Enter to keep '$(get_effective_ram)'):"
    read -r v; [[ -n "$v" ]] && export OVERRIDE_RAM="$v"
}

_cmd_backup() {
    local targets="all"
    local user_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)     targets="$2";     shift 2 ;;
            --user)       user_filter="$2"; shift 2 ;;
            --all-users)  user_filter="";   shift   ;;
            --dry-run)    DRY_RUN=true; export DRY_RUN; shift ;;
            *) echo_warn "Unknown option: $1"; shift ;;
        esac
    done

    # Load per-app backup modules
    for mod in rtorrent qbittorrent deluge transmission plex; do
        source "${TOOLKIT_ROOT}/lib/backup/${mod}.sh"
    done

    run_backup --target "$targets" ${user_filter:+--user "$user_filter"}
}

_cmd_restore() {
    local archive_path=""
    local app_filter=""
    local user_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)   archive_path="$2"; shift 2 ;;
            --target) app_filter="$2";   shift 2 ;;
            --user)   user_filter="$2";  shift 2 ;;
            --dry-run) DRY_RUN=true; export DRY_RUN; shift ;;
            *) echo_warn "Unknown option: $1"; shift ;;
        esac
    done

    # Load per-app backup modules
    for mod in rtorrent qbittorrent deluge transmission plex; do
        source "${TOOLKIT_ROOT}/lib/backup/${mod}.sh"
    done

    run_restore \
        ${archive_path:+--file "$archive_path"} \
        ${app_filter:+--target "$app_filter"} \
        ${user_filter:+--user "$user_filter"}
}

_cmd_list() {
    local app_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app_filter="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    list_backups "$app_filter"
}

_cmd_rollback() {
    local timestamp=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timestamp) timestamp="$2"; shift 2 ;;
            --dry-run)   DRY_RUN=true; export DRY_RUN; shift ;;
            *) shift ;;
        esac
    done
    run_rollback "$timestamp"
}

_cmd_status() {
    detect_all_hardware
    display_hardware_info
    display_swizzin_status
}

# ─── Help ─────────────────────────────────────────────────────────────────────

_show_help() {
    cat <<'EOF'
swizzin-toolkit — Server and torrent client tuning + backup

USAGE:
  toolkit [SUBCOMMAND] [OPTIONS]

  With no subcommand, opens the interactive menu (requires a terminal).

SUBCOMMANDS:

  tune     Tune server and torrent clients
    --auto              Auto-detect hardware (default)
    --manual            Manually specify hardware parameters
    --dry-run           Show what would be changed, make no changes
    --yes               Skip confirmation prompts
    --target TARGETS    Comma-separated targets (default: all)
                        Targets: kernel network disk rtorrent qbittorrent
                                 deluge transmission plex all
    --profile PROFILE   Override profile: light | medium | heavy
    --disk-type TYPE    Override disk:    NVME | SSD | HDD
    --ram GB            Override RAM in GB
    --net-speed Mbps    Override network speed in Mbps

  backup   Create backups of torrent clients and Plex
    --target TARGETS    Comma-separated apps (default: all)
                        Apps: rtorrent qbittorrent deluge transmission plex all
    --user USER         Backup only for this user
    --dry-run           Show what would be backed up

  restore  Restore from backup
    --file ARCHIVE      Specific archive to restore
    --target APP        Filter to specific app
    --user USER         Filter to specific user
    --dry-run           Show what would be restored

  list     List available backups
    --app APP           Filter by app name

  rollback Rollback last tuning changes
    --timestamp TS      Specify session timestamp to rollback
    --dry-run           Show what would be restored

  status   Show detected hardware and installed apps

  help     Show this help message

EXAMPLES:
  toolkit tune --auto --target all
  toolkit tune --dry-run --target kernel,network
  toolkit tune --manual --profile heavy --disk-type NVME
  toolkit backup --target rtorrent,plex
  toolkit backup --target all --user alice
  toolkit list --app plex
  toolkit restore --target rtorrent --user alice
  toolkit rollback
  toolkit status

CONFIGURATION:
  Override defaults by setting environment variables before calling toolkit:
    TOOLKIT_BACKUP_ROOT   Where to store backups (default: /root/swizzin-toolkit-backups)
    BACKUP_RETENTION_COUNT  How many backups to keep per app (default: 10)
    PLEX_DATA_PATH        Plex data directory path
    TOOLKIT_LOG           Log file path (default: /var/log/swizzin-toolkit.log)

EOF
}

# ─── Entry point ─────────────────────────────────────────────────────────────

main "$@"
