#!/usr/bin/env bash
# lib/ui/backup_menu.sh — Backup/restore/list sub-menus

[[ -n "${_TOOLKIT_UI_BACKUP_MENU_LOADED:-}" ]] && return 0
_TOOLKIT_UI_BACKUP_MENU_LOADED=1

run_backup_menu() {
    if has_whiptail; then
        _backup_menu_whiptail
    else
        _backup_menu_select
    fi
}

run_restore_menu() {
    if has_whiptail; then
        run_restore
    else
        _restore_menu_select
    fi
}

_backup_menu_whiptail() {
    local action
    action=$(whiptail --title "Backup" \
        --menu "Choose an action:" 14 60 5 \
        "backup"  "Create new backup" \
        "list"    "List available backups" \
        "restore" "Restore from backup" \
        "cleanup" "Enforce retention policy now" \
        "back"    "Back to main menu" \
        3>&1 1>&2 2>&3) || return 0

    case "$action" in
        backup)  _backup_target_whiptail ;;
        list)    list_backups; echo_query "Press Enter..."; read -r _ ;;
        restore) run_restore ;;
        cleanup) enforce_retention; echo_success "Retention enforced"; echo_query "Press Enter..."; read -r _ ;;
        back|"") return 0 ;;
    esac
}

_backup_target_whiptail() {
    local -a checklist=()
    for app in rtorrent qbittorrent deluge transmission plex; do
        local state="OFF"
        is_app_installed "$app" 2>/dev/null && state="ON"
        checklist+=("$app" "Backup ${app}" "$state")
    done

    local selected
    selected=$(whiptail --title "Backup — Select Targets" \
        --checklist "Select apps to backup:" 16 60 7 \
        "${checklist[@]}" \
        3>&1 1>&2 2>&3) || return 0

    selected=$(echo "$selected" | tr -d '"')
    [[ -z "$selected" ]] && selected="all"

    run_backup --target "$selected"
}

_backup_menu_select() {
    echo_header "Backup"
    PS3="Select action: "
    select action in "Create backup" "List backups" "Restore" "Enforce retention" "Back"; do
        case "$action" in
            "Create backup")      run_backup ;;
            "List backups")       list_backups ;;
            "Restore")            run_restore  ;;
            "Enforce retention")  enforce_retention ;;
            "Back")               return 0 ;;
        esac
        break
    done
}

_restore_menu_select() {
    echo_header "Restore"
    echo "Available backups:"
    list_backups
    echo_query "Enter archive path (or press Enter to cancel):"
    local path
    read -r path
    [[ -z "$path" ]] && return 0
    run_restore --file "$path"
}
