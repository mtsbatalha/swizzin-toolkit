#!/usr/bin/env bash
# lib/backup/rtorrent.sh — rTorrent backup and restore

[[ -n "${_TOOLKIT_BACKUP_RTORRENT_LOADED:-}" ]] && return 0
_TOOLKIT_BACKUP_RTORRENT_LOADED=1

backup_rtorrent_all() {
    local session_dir="$1"
    local user_filter="${2:-}"

    if ! is_app_installed rtorrent; then
        echo_info "rTorrent not installed — skipping backup"
        return 0
    fi

    local users
    mapfile -t users < <(get_all_users)

    for user in "${users[@]}"; do
        [[ -n "$user_filter" ]] && [[ "$user" != "$user_filter" ]] && continue
        [[ -f "/home/${user}/.rtorrent.rc" ]] || continue
        backup_rtorrent_user "$user" "$session_dir"
    done
}

backup_rtorrent_user() {
    local user="$1"
    local session_dir="$2"

    local archive="${session_dir}/rtorrent_${user}.tar.gz"
    local home="/home/${user}"

    echo_progress_start "Backing up rTorrent for ${user}..."

    # Include: rc file, sessions dir, watch dirs
    local -a paths=()
    [[ -f "${home}/.rtorrent.rc" ]] && paths+=("${home}/.rtorrent.rc")
    [[ -d "${home}/.sessions"    ]] && paths+=("${home}/.sessions")
    [[ -d "${home}/rwatch"       ]] && paths+=("${home}/rwatch")

    if [[ ${#paths[@]} -eq 0 ]]; then
        echo_warn "No rTorrent files found for ${user}"
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would create: ${archive}"
        echo_dry_run "  Paths: ${paths[*]}"
        echo_progress_done
        return 0
    fi

    tar -czf "$archive" "${paths[@]}" 2>/dev/null
    verify_archive "$archive" && echo_progress_done || echo_warn "Archive verification failed for ${user}"
}

restore_rtorrent_user() {
    local user="$1"
    local archive="$2"

    local home="/home/${user}"
    local service="rtorrent@${user}"

    echo_progress_start "Restoring rTorrent for ${user}..."

    # Safety backup of current config
    [[ -f "${home}/.rtorrent.rc" ]] && backup_file "${home}/.rtorrent.rc"

    # Stop service if running
    local was_running=false
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        was_running=true
        service_stop_start stop "$service"
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would extract ${archive} to /"
    else
        tar -xzf "$archive" -C / 2>/dev/null
        chown -R "${user}:${user}" "${home}/.rtorrent.rc" "${home}/.sessions" 2>/dev/null || true
    fi

    [[ "$was_running" == true ]] && service_stop_start start "$service"
    echo_progress_done
}
