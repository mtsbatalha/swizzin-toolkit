#!/usr/bin/env bash
# lib/tune/qbittorrent.sh — qBittorrent per-user config tuning
# Modifies ~/.config/qBittorrent/qBittorrent.conf (Qt INI format).
# Service is stopped before modification and restarted after.

[[ -n "${_TOOLKIT_TUNE_QBITTORRENT_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_QBITTORRENT_LOADED=1

tune_qbittorrent() {
    echo_header "qBittorrent Tuning"

    if ! is_app_installed qbittorrent; then
        echo_warn "qBittorrent is not installed — skipping"
        return 0
    fi

    local users
    mapfile -t users < <(get_all_users)
    local tuned=0

    for user in "${users[@]}"; do
        local config="/home/${user}/.config/qBittorrent/qBittorrent.conf"
        [[ -f "$config" ]] || continue
        echo_progress_start "Tuning qBittorrent for user: ${user}..."
        tune_qbittorrent_user "$user" "$config"
        echo_progress_done
        (( tuned++ ))
    done

    if [[ $tuned -eq 0 ]]; then
        echo_warn "No qBittorrent config files found for any user"
        return 0
    fi

    echo_success "qBittorrent tuned for ${tuned} user(s)"
}

tune_qbittorrent_user() {
    local user="$1"
    local config="$2"

    local profile disk cpu
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)
    cpu=$(get_effective_cpu)

    # Back up before modifying
    backup_file "$config"

    # Calculate parameters
    local max_conn max_conn_per max_uploads max_uploads_per \
          disk_cache_mb io_threads file_pool \
          active_dl active_ul active_total

    case "$profile" in
        light)
            max_conn=200;        max_conn_per=50;     max_uploads=50;    max_uploads_per=10
            disk_cache_mb=64;    io_threads=4;        file_pool=100
            active_dl=5;         active_ul=5;         active_total=10
            ;;
        medium)
            max_conn=500;        max_conn_per=100;    max_uploads=100;   max_uploads_per=20
            disk_cache_mb=256;   io_threads=8;        file_pool=500
            active_dl=10;        active_ul=10;        active_total=20
            ;;
        heavy|*)
            max_conn=1000;       max_conn_per=200;    max_uploads=200;   max_uploads_per=40
            disk_cache_mb=2048;  io_threads=16;       file_pool=1000
            active_dl=20;        active_ul=20;        active_total=50
            ;;
    esac

    # Disk-aware async I/O thread multiplier
    case "$disk" in
        NVME) io_threads=$(( io_threads * 2 )) ;;
        SSD)  : ;;   # keep as-is
        HDD)  io_threads=$(( io_threads / 2 < 2 ? 2 : io_threads / 2 )) ;;
    esac

    # Cap to available CPU cores
    local cpu_cap=$(( cpu * 2 ))
    io_threads=$(( io_threads > cpu_cap ? cpu_cap : io_threads ))

    # Stop service before modifying (qBt writes config on shutdown)
    local service="qbittorrent@${user}"
    local was_running=false
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        was_running=true
        service_stop_start stop "$service"
    fi

    # Apply settings to [BitTorrent] section
    # Qt INI uses \\n for separator but actual parameter names vary by version.
    # We use the format that qBittorrent writes: "Session\Key=Value"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxConnections'           "$max_conn"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxConnectionsPerTorrent' "$max_conn_per"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxUploads'               "$max_uploads"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxUploadsPerTorrent'     "$max_uploads_per"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\DiskCacheSize'            "$disk_cache_mb"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\AsyncIOThreadsCount'      "$io_threads"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\FilePoolSize'             "$file_pool"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxActiveDownloads'       "$active_dl"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxActiveUploads'         "$active_ul"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\MaxActiveTorrents'        "$active_total"
    _set_qbt_value "$config" "[BitTorrent]" 'Session\UseOSCache'               "true"

    # Restart only if it was running
    if [[ "$was_running" == true ]]; then
        service_stop_start start "$service"
    fi
}

# Safely set a key in a specific section of a Qt INI file.
# Qt INI uses "Key=Value" with no spaces around = within sections.
# Usage: _set_qbt_value /path/to/file "[SectionName]" "KeyName" "value"
_set_qbt_value() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "  qBittorrent: ${section} ${key}=${value}"
        return 0
    fi

    # Escape the key for awk pattern matching (backslashes, dots)
    local awk_key
    awk_key=$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/\./\\./g')

    if ! grep -qF "$section" "$file"; then
        # Section doesn't exist — append it
        printf '\n%s\n%s=%s\n' "$section" "$key" "$value" >> "$file"
        return 0
    fi

    # Check if key exists within the section
    local key_exists
    key_exists=$(awk -v sec="$section" -v k="$awk_key" '
        $0 == sec { in_sec=1; next }
        /^\[/ { in_sec=0 }
        in_sec && $0 ~ "^"k"=" { print "yes"; exit }
    ' "$file")

    if [[ "$key_exists" == "yes" ]]; then
        # Replace in-section
        awk -v sec="$section" -v k="$awk_key" -v v="$value" '
            $0 == sec { in_sec=1; print; next }
            /^\[/ { in_sec=0 }
            in_sec && $0 ~ "^"k"=" { print k"="v; next }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        # Insert after section header
        awk -v sec="$section" -v k="$key" -v v="$value" '
            $0 == sec { print; print k"="v; next }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}
