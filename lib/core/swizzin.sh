#!/usr/bin/env bash
# lib/core/swizzin.sh — Swizzin integration helpers
# Detects swizzin installation, enumerates users, and checks installed apps.
# Works in three modes: full swizzin, partial swizzin, or standalone.

[[ -n "${_TOOLKIT_SWIZZIN_LOADED:-}" ]] && return 0
_TOOLKIT_SWIZZIN_LOADED=1

# ─── Swizzin detection ───────────────────────────────────────────────────────

# Returns 0 if swizzin appears to be fully installed
is_swizzin_installed() {
    [[ -f "${SWIZZIN_GLOBALS:-/etc/swizzin/sources/globals.sh}" ]]
}

# Attempt to source swizzin's function library (non-fatal)
# Swizzin scripts are not written with set -u in mind, so we temporarily
# disable nounset before sourcing them to prevent "unbound variable" errors.
load_swizzin_functions() {
    if is_swizzin_installed; then
        set +u
        # shellcheck disable=SC1090
        source "${SWIZZIN_GLOBALS}" 2>/dev/null || true
        # Source additional function libraries if present
        # Only source 'users' — we skip 'color_echo' since swizzin's version
        # uses unguarded $1 and conflicts with set -u in our environment.
        local func_dir="/etc/swizzin/sources/functions"
        [[ -f "${func_dir}/users" ]] && source "${func_dir}/users" 2>/dev/null || true
        set -u
    fi
}

# ─── User enumeration ────────────────────────────────────────────────────────

# Get list of swizzin users via /root/*.info files (swizzin canonical method)
_get_swizzin_users() {
    local users=()
    for info_file in /root/*.info; do
        [[ -f "$info_file" ]] || continue
        local username
        username=$(cut -d: -f1 < "$info_file" 2>/dev/null)
        [[ -n "$username" ]] && users+=("$username")
    done
    printf '%s\n' "${users[@]}"
}

# Get list of regular users from /etc/passwd (fallback for non-swizzin systems)
_get_passwd_users() {
    getent passwd 2>/dev/null \
        | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /nologin|false/ { print $1 }'
}

# Returns the list of users relevant to the toolkit
# Uses swizzin method if available, otherwise falls back to passwd
get_all_users() {
    if is_swizzin_installed && [[ -f "/root/.master.info" ]]; then
        _get_swizzin_users
    else
        _get_passwd_users
    fi
}

# Returns the master/primary user on a swizzin box
get_master_user() {
    if [[ -f "${SWIZZIN_MASTER_INFO:-/root/.master.info}" ]]; then
        cut -d: -f1 < "${SWIZZIN_MASTER_INFO}" 2>/dev/null
    else
        # Fallback: first user from get_all_users
        get_all_users | head -1
    fi
}

# ─── App detection ───────────────────────────────────────────────────────────

# Returns 0 if the given application is installed
# Checks: swizzin lock file → systemd unit → known binary
# Usage: is_app_installed rtorrent
is_app_installed() {
    local app="$1"
    local lock_dir="${SWIZZIN_LOCK_DIR:-/install}"

    # Method 1: swizzin lock file (canonical)
    if [[ -f "${lock_dir}/.${app}.lock" ]]; then
        return 0
    fi

    # Method 2: systemd service exists (template or direct)
    if systemctl list-units --full --all 2>/dev/null \
        | grep -qE "^${app}(@[^.]+)?\.service"; then
        return 0
    fi

    # Method 3: known binary path
    case "$app" in
        rtorrent)     command -v rtorrent >/dev/null 2>&1 && return 0 ;;
        deluge)       command -v deluged  >/dev/null 2>&1 && return 0 ;;
        qbittorrent)  command -v qbittorrent-nox >/dev/null 2>&1 && return 0 ;;
        transmission) command -v transmission-daemon >/dev/null 2>&1 && return 0 ;;
        plex)
            systemctl is-active --quiet plexmediaserver 2>/dev/null && return 0
            [[ -f /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml ]] && return 0
            ;;
    esac

    return 1
}

# Returns a space-separated list of installed torrent clients
get_installed_clients() {
    local clients=()
    for app in rtorrent qbittorrent deluge transmission; do
        is_app_installed "$app" && clients+=("$app")
    done
    echo "${clients[*]}"
}

# ─── Display swizzin status ──────────────────────────────────────────────────

display_swizzin_status() {
    echo_header "Swizzin Integration"
    if is_swizzin_installed; then
        echo_success "Swizzin installation detected"
        printf "  %-22s %s\n" "Globals:" "${SWIZZIN_GLOBALS}"
    else
        echo_info "Swizzin not detected — running in standalone mode"
    fi

    local master
    master=$(get_master_user)
    printf "  %-22s %s\n" "Master user:" "${master:-unknown}"

    echo
    echo_step "Installed applications:"
    local line=""
    for app in rtorrent qbittorrent deluge transmission plex; do
        if is_app_installed "$app"; then
            line+="  [x] ${app}"
        else
            line+="  [ ] ${app}"
        fi
    done
    echo "$line" | tr '  ' '\n' | grep '^\[' | column -t
    echo

    echo_step "Users:"
    while IFS= read -r user; do
        printf "  - %s\n" "$user"
    done < <(get_all_users)
    echo
}
