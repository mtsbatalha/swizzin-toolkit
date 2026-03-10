#!/usr/bin/env bash
# lib/tune/deluge.sh — Deluge per-user config tuning
# Modifies ~/.config/deluge/core.conf (JSON format) using Python3.
# Service is stopped before modification and restarted after.

[[ -n "${_TOOLKIT_TUNE_DELUGE_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_DELUGE_LOADED=1

tune_deluge() {
    echo_header "Deluge Tuning"

    if ! is_app_installed deluge; then
        echo_warn "Deluge is not installed — skipping"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo_error "python3 is required for Deluge tuning but not found"
        return 1
    fi

    local users
    mapfile -t users < <(get_all_users)
    local tuned=0

    for user in "${users[@]}"; do
        local config="/home/${user}/.config/deluge/core.conf"
        [[ -f "$config" ]] || continue
        echo_progress_start "Tuning Deluge for user: ${user}..."
        tune_deluge_user "$user" "$config"
        echo_progress_done
        (( tuned++ ))
    done

    if [[ $tuned -eq 0 ]]; then
        echo_warn "No Deluge config files found for any user"
        return 0
    fi

    echo_success "Deluge tuned for ${tuned} user(s)"
}

tune_deluge_user() {
    local user="$1"
    local config="$2"

    local profile disk
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)

    # Back up before modifying
    backup_file "$config"

    # Stop deluged and deluge-web before modifying (Deluge may overwrite on exit)
    local was_running=false
    if systemctl is-active --quiet "deluged@${user}" 2>/dev/null; then
        was_running=true
        service_stop_start stop "deluged@${user}"
        service_stop_start stop "deluge-web@${user}" 2>/dev/null || true
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would update ${config} with ${profile} profile, ${disk} disk settings"
    else
        _update_deluge_json "$config" "$profile" "$disk"
        # Fix ownership
        chown "${user}:${user}" "$config" 2>/dev/null || true
    fi

    if [[ "$was_running" == true ]]; then
        service_stop_start start "deluged@${user}"
        service_stop_start start "deluge-web@${user}" 2>/dev/null || true
    fi
}

_update_deluge_json() {
    local config="$1"
    local profile="$2"
    local disk="$3"

    python3 - "$config" "$profile" "$disk" <<'PYEOF'
import json
import sys

config_file, profile, disk = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_file, 'r') as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: Failed to parse {config_file}: {e}", file=sys.stderr)
        sys.exit(1)

# Profile-based connection and queue limits
limits = {
    "light":  {
        "max_connections_global":   200,
        "max_upload_slots_global":  50,
        "max_active_downloading":   5,
        "max_active_seeding":       10,
        "max_active_limit":         20,
        "max_half_open_connections": 20,
    },
    "medium": {
        "max_connections_global":   500,
        "max_upload_slots_global":  100,
        "max_active_downloading":   10,
        "max_active_seeding":       20,
        "max_active_limit":         40,
        "max_half_open_connections": 50,
    },
    "heavy": {
        "max_connections_global":   1000,
        "max_upload_slots_global":  200,
        "max_active_downloading":   20,
        "max_active_seeding":       40,
        "max_active_limit":         100,
        "max_half_open_connections": 100,
    },
}

cfg.update(limits.get(profile, limits["medium"]))

# Cache size by profile (in 16 KB blocks — Deluge stores cache_size in number of 16KB blocks)
cache_sizes = {"light": 256, "medium": 512, "heavy": 2048}  # MB
cache_expiry = {"light": 60,  "medium": 120, "heavy": 300}  # seconds
cache_mb = cache_sizes.get(profile, 512)
cfg["cache_size"] = (cache_mb * 1024 * 1024) // 16384  # convert MB to 16KB blocks
cfg["cache_expiry"] = cache_expiry.get(profile, 120)

# Disk-specific max_active_limit and slow_torrents
disk_settings = {
    "NVME": {"max_active_limit": 100, "dont_count_slow_torrents": True},
    "SSD":  {"max_active_limit": 50,  "dont_count_slow_torrents": True},
    "HDD":  {"max_active_limit": 30,  "dont_count_slow_torrents": False},
}
cfg.update(disk_settings.get(disk, disk_settings["SSD"]))

# Network performance settings
cfg["peer_tos"] = "0x08"             # throughput-optimized ToS
cfg["utpex_enabled"] = True
cfg["lsd_enabled"] = False           # disable local service discovery on DC

# Save
with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=2, sort_keys=True)

print(f"OK: updated {config_file} (profile={profile}, disk={disk})")
PYEOF
}
