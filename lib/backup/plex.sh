#!/usr/bin/env bash
# lib/backup/plex.sh — Plex Media Server full backup and restore
# Backs up the Plex application data directory (metadata, preferences, DB).

[[ -n "${_TOOLKIT_BACKUP_PLEX_LOADED:-}" ]] && return 0
_TOOLKIT_BACKUP_PLEX_LOADED=1

# Default Plex data path (can be overridden via PLEX_DATA_PATH env)
_PLEX_DATA="${PLEX_DATA_PATH:-/var/lib/plexmediaserver/Library/Application Support/Plex Media Server}"

backup_plex() {
    local session_dir="$1"
    local archive="${session_dir}/plex_system.tar.gz"

    if ! is_app_installed plex; then
        echo_info "Plex Media Server not installed — skipping backup"
        return 0
    fi

    if [[ ! -d "${_PLEX_DATA}" ]]; then
        echo_warn "Plex data directory not found: ${_PLEX_DATA}"
        return 0
    fi

    # Warn if backup would be large
    local size_estimate
    size_estimate=$(du -sh "${_PLEX_DATA}" 2>/dev/null | cut -f1)
    echo_info "Plex data size: ${size_estimate}"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would create: ${archive}"
        echo_dry_run "  Source: ${_PLEX_DATA}"
        return 0
    fi

    echo_progress_start "Backing up Plex Media Server (${size_estimate})..."
    echo_info "This may take a while for large libraries..."

    # Use tar with --warning=no-file-changed to suppress changed-during-backup warnings
    tar -czf "$archive" \
        --warning=no-file-changed \
        --exclude="${_PLEX_DATA}/Cache" \
        --exclude="${_PLEX_DATA}/Crash Reports" \
        --exclude="${_PLEX_DATA}/Logs" \
        "${_PLEX_DATA}" 2>/dev/null

    verify_archive "$archive" && echo_progress_done || echo_warn "Plex archive verification failed"
}

restore_plex() {
    local archive="$1"

    echo_progress_start "Restoring Plex Media Server..."

    # Safety backup of preferences file
    local prefs="${_PLEX_DATA}/Preferences.xml"
    [[ -f "$prefs" ]] && backup_file "$prefs"

    # Stop Plex before restoring
    local was_running=false
    if systemctl is-active --quiet plexmediaserver 2>/dev/null; then
        was_running=true
        service_stop_start stop plexmediaserver
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would extract ${archive} to /"
    else
        # Extract preserving full paths
        tar -xzf "$archive" -C / 2>/dev/null
        # Fix ownership (plex runs as plex:plex by default)
        chown -R plex:plex "${_PLEX_DATA}" 2>/dev/null || \
            chown -R "$(stat -c '%U:%G' "${_PLEX_DATA}" 2>/dev/null || echo 'plex:plex')" "${_PLEX_DATA}" 2>/dev/null || true
    fi

    [[ "$was_running" == true ]] && service_stop_start start plexmediaserver
    echo_progress_done
}
