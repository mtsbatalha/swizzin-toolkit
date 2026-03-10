#!/usr/bin/env bash
# lib/backup/qbittorrent.sh — qBittorrent backup and restore

[[ -n "${_TOOLKIT_BACKUP_QBITTORRENT_LOADED:-}" ]] && return 0
_TOOLKIT_BACKUP_QBITTORRENT_LOADED=1

backup_qbittorrent_all() {
    local session_dir="$1"
    local user_filter="${2:-}"

    if ! is_app_installed qbittorrent; then
        echo_info "qBittorrent not installed — skipping backup"
        return 0
    fi

    local users
    mapfile -t users < <(get_all_users)

    for user in "${users[@]}"; do
        [[ -n "$user_filter" ]] && [[ "$user" != "$user_filter" ]] && continue
        [[ -d "/home/${user}/.config/qBittorrent" ]] || continue
        backup_qbittorrent_user "$user" "$session_dir"
    done
}

backup_qbittorrent_user() {
    local user="$1"
    local session_dir="$2"

    local archive="${session_dir}/qbittorrent_${user}.tar.gz"
    local config_dir="/home/${user}/.config/qBittorrent"

    echo_progress_start "Backing up qBittorrent for ${user}..."

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would create: ${archive}"
        echo_dry_run "  Source: ${config_dir}"
        echo_progress_done
        return 0
    fi

    tar -czf "$archive" "$config_dir" 2>/dev/null
    verify_archive "$archive" && echo_progress_done || echo_warn "Archive verification failed for ${user}"
}

restore_qbittorrent_user() {
    local user="$1"
    local archive="$2"

    local config_dir="/home/${user}/.config/qBittorrent"
    local service="qbittorrent@${user}"

    echo_progress_start "Restoring qBittorrent for ${user}..."

    # Safety backup
    [[ -d "$config_dir" ]] && backup_file "${config_dir}/qBittorrent.conf"

    # qBittorrent should be stopped during restore (it may overwrite on shutdown)
    local was_running=false
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        was_running=true
        service_stop_start stop "$service"
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would extract ${archive} to /"
    else
        tar -xzf "$archive" -C / 2>/dev/null
        chown -R "${user}:${user}" "$config_dir" 2>/dev/null || true
    fi

    [[ "$was_running" == true ]] && service_stop_start start "$service"
    echo_progress_done
}
