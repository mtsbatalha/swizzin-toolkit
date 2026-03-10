#!/usr/bin/env bash
# lib/ui/menu.sh — Top-level interactive menu (whiptail + select fallback)

[[ -n "${_TOOLKIT_UI_MENU_LOADED:-}" ]] && return 0
_TOOLKIT_UI_MENU_LOADED=1

_UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui/tune_menu.sh
source "${_UI_DIR}/tune_menu.sh"
# shellcheck source=lib/ui/backup_menu.sh
source "${_UI_DIR}/backup_menu.sh"

has_whiptail() {
    command -v whiptail >/dev/null 2>&1
}

# ─── Main menu ───────────────────────────────────────────────────────────────

run_main_menu() {
    if has_whiptail; then
        _main_menu_whiptail
    else
        _main_menu_select
    fi
}

_main_menu_whiptail() {
    while true; do
        local choice
        choice=$(whiptail --title "swizzin-toolkit" \
            --menu "Choose an action:" 18 60 8 \
            "tune"    "Tune server and torrent clients" \
            "backup"  "Backup torrent clients and Plex" \
            "restore" "Restore from backup" \
            "list"    "List available backups" \
            "status"  "Show system status" \
            "rollback" "Rollback last tuning changes" \
            "exit"    "Exit" \
            3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            tune)    run_tune_menu    ;;
            backup)  run_backup_menu  ;;
            restore) run_restore_menu ;;
            list)    list_backups; _pause ;;
            status)  _show_status; _pause ;;
            rollback) run_rollback; _pause ;;
            exit|"") return 0 ;;
        esac
    done
}

_main_menu_select() {
    echo_header "swizzin-toolkit"
    PS3="Select action: "
    select action in "Tune" "Backup" "Restore" "List backups" "Status" "Rollback" "Exit"; do
        case "$action" in
            "Tune")         run_tune_menu   ;;
            "Backup")       run_backup_menu ;;
            "Restore")      run_restore_menu;;
            "List backups") list_backups    ;;
            "Status")       _show_status    ;;
            "Rollback")     run_rollback    ;;
            "Exit")         return 0        ;;
        esac
        break
    done
}

_show_status() {
    [[ -z "${DETECTED_RAM:-}" ]] && detect_all_hardware
    display_hardware_info
    display_swizzin_status
}

_pause() {
    echo
    echo_query "Press Enter to continue..."
    read -r _
}
