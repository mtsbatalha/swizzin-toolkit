#!/usr/bin/env bash
# lib/backup/deluge.sh — Deluge backup and restore

[[ -n "${_TOOLKIT_BACKUP_DELUGE_LOADED:-}" ]] && return 0
_TOOLKIT_BACKUP_DELUGE_LOADED=1

backup_deluge_all() {
    local session_dir="$1"
    local user_filter="${2:-}"

    if ! is_app_installed deluge; then
        echo_info "Deluge not installed — skipping backup"
        return 0
    fi

    local users
    mapfile -t users < <(get_all_users)

    for user in "${users[@]}"; do
        [[ -n "$user_filter" ]] && [[ "$user" != "$user_filter" ]] && continue
        [[ -d "/home/${user}/.config/deluge" ]] || continue
        backup_deluge_user "$user" "$session_dir"
    done
}

backup_deluge_user() {
    local user="$1"
    local session_dir="$2"

    local archive="${session_dir}/deluge_${user}.tar.gz"
    local config_dir="/home/${user}/.config/deluge"

    echo_progress_start "Backing up Deluge for ${user}..."

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would create: ${archive}"
        echo_dry_run "  Source: ${config_dir}"
        echo_progress_done
        return 0
    fi

    tar -czf "$archive" "$config_dir" 2>/dev/null
    verify_archive "$archive" && echo_progress_done || echo_warn "Archive verification failed for ${user}"
}

restore_deluge_user() {
    local user="$1"
    local archive="$2"

    local config_dir="/home/${user}/.config/deluge"

    echo_progress_start "Restoring Deluge for ${user}..."

    # Safety backup of core.conf
    [[ -f "${config_dir}/core.conf" ]] && backup_file "${config_dir}/core.conf"

    # Stop services
    local daemon_was_running=false
    local web_was_running=false
    if systemctl is-active --quiet "deluged@${user}" 2>/dev/null; then
        daemon_was_running=true
        service_stop_start stop "deluged@${user}"
    fi
    if systemctl is-active --quiet "deluge-web@${user}" 2>/dev/null; then
        web_was_running=true
        service_stop_start stop "deluge-web@${user}"
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would extract ${archive} to /"
    else
        tar -xzf "$archive" -C / 2>/dev/null
        chown -R "${user}:${user}" "$config_dir" 2>/dev/null || true
    fi

    [[ "$daemon_was_running" == true ]] && service_stop_start start "deluged@${user}"
    [[ "$web_was_running"    == true ]] && service_stop_start start "deluge-web@${user}"
    echo_progress_done
}
