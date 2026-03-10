#!/usr/bin/env bash
# lib/tune/rtorrent.sh — rTorrent per-user config tuning
# Modifies /home/{user}/.rtorrent.rc for all users with rtorrent installed.

[[ -n "${_TOOLKIT_TUNE_RTORRENT_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_RTORRENT_LOADED=1

tune_rtorrent() {
    echo_header "rTorrent Tuning"

    if ! is_app_installed rtorrent; then
        echo_warn "rTorrent is not installed — skipping"
        return 0
    fi

    local users
    mapfile -t users < <(get_all_users)
    local tuned=0

    for user in "${users[@]}"; do
        local config="/home/${user}/.rtorrent.rc"
        [[ -f "$config" ]] || continue
        echo_progress_start "Tuning rTorrent for user: ${user}..."
        tune_rtorrent_user "$user" "$config"
        echo_progress_done
        (( tuned++ ))
    done

    if [[ $tuned -eq 0 ]]; then
        echo_warn "No rTorrent config files found for any user"
        return 0
    fi

    echo_success "rTorrent tuned for ${tuned} user(s)"
}

tune_rtorrent_user() {
    local user="$1"
    local config="$2"

    local profile disk
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)

    # Back up before modifying
    backup_file "$config"

    # Calculate parameters
    local max_peers_normal max_peers_seed max_uploads hash_max_tries \
          hash_read_ahead preload_min_rate recv_buf send_buf max_open_files \
          max_open_http

    case "$profile" in
        light)
            max_peers_normal=50;  max_peers_seed=80;   max_uploads=50
            hash_max_tries=5;     hash_read_ahead=10
            max_open_files=600;   max_open_http=32
            recv_buf=4194304;     send_buf=1048576   # 4M/1M
            ;;
        medium)
            max_peers_normal=100; max_peers_seed=150;  max_uploads=100
            hash_max_tries=10;    hash_read_ahead=20
            max_open_files=1200;  max_open_http=64
            recv_buf=8388608;     send_buf=2097152   # 8M/2M
            ;;
        heavy|*)
            max_peers_normal=200; max_peers_seed=300;  max_uploads=200
            hash_max_tries=20;    hash_read_ahead=40
            max_open_files=2400;  max_open_http=128
            recv_buf=16777216;    send_buf=4194304   # 16M/4M
            ;;
    esac

    # Disk-aware preload rate (KB/s)
    case "$disk" in
        NVME) preload_min_rate=102400 ;;   # 100k
        SSD)  preload_min_rate=51200  ;;   # 50k
        HDD)  preload_min_rate=20480  ;;   # 20k
    esac

    # Apply each parameter
    _set_rtorrent_param "$config" "throttle.max_peers.normal.set"  "$max_peers_normal"
    _set_rtorrent_param "$config" "throttle.max_peers.seed.set"    "$max_peers_seed"
    _set_rtorrent_param "$config" "throttle.max_uploads.global.set" "$max_uploads"
    _set_rtorrent_param "$config" "pieces.hash.max_tries.set"       "$hash_max_tries"
    _set_rtorrent_param "$config" "pieces.hash.read_ahead.set"      "$hash_read_ahead"
    _set_rtorrent_param "$config" "pieces.preload.min_rate.set"     "$preload_min_rate"
    _set_rtorrent_param "$config" "network.receive_buffer.size.set" "$recv_buf"
    _set_rtorrent_param "$config" "network.send_buffer.size.set"    "$send_buf"
    _set_rtorrent_param "$config" "network.max_open_files.set"      "$max_open_files"
    _set_rtorrent_param "$config" "network.http.max_open.set"       "$max_open_http"

    # Restart service if running
    local service="rtorrent@${user}"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        service_stop_start restart "$service"
    fi
}

# Set or append a parameter in .rtorrent.rc
# rtorrent.rc uses "key = value" format
_set_rtorrent_param() {
    local config="$1"
    local key="$2"
    local value="$3"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "  rtorrent: ${key} = ${value}"
        return 0
    fi

    # Check if the key exists (with or without spaces around =)
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$config" 2>/dev/null; then
        # Replace the existing line
        sed_in_place "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$config"
    else
        # Append to file
        echo "${key} = ${value}" >> "$config"
    fi
}
