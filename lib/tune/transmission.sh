#!/usr/bin/env bash
# lib/tune/transmission.sh — Transmission per-user config tuning [NEW]
# Modifies ~/.config/transmission-daemon/settings.json using Python3.
#
# IMPORTANT: Transmission OVERWRITES settings.json when the daemon shuts down.
# Therefore the service MUST be stopped before modifying the file.
#
# Key design decisions:
#   - preallocation=2 (full) for HDD: reduces fragmentation, improves sequential I/O
#   - preallocation=1 (sparse) for NVMe/SSD: sparse files are fine on fast storage
#   - seed-queue-size tuned aggressively because seeding ratio is critical on seedboxes
#   - lpd-enabled=false: Local Peer Discovery is useless in a datacenter

[[ -n "${_TOOLKIT_TUNE_TRANSMISSION_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_TRANSMISSION_LOADED=1

tune_transmission() {
    echo_header "Transmission Tuning"

    if ! is_app_installed transmission; then
        echo_warn "Transmission is not installed — skipping"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo_error "python3 is required for Transmission tuning but not found"
        return 1
    fi

    local users
    mapfile -t users < <(get_all_users)
    local tuned=0

    for user in "${users[@]}"; do
        local config="/home/${user}/.config/transmission-daemon/settings.json"
        [[ -f "$config" ]] || continue
        echo_progress_start "Tuning Transmission for user: ${user}..."
        tune_transmission_user "$user" "$config"
        echo_progress_done
        (( tuned++ ))
    done

    if [[ $tuned -eq 0 ]]; then
        echo_warn "No Transmission config files found for any user"
        return 0
    fi

    echo_success "Transmission tuned for ${tuned} user(s)"
}

tune_transmission_user() {
    local user="$1"
    local config="$2"

    local profile disk
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)

    # Back up before modifying
    backup_file "$config"

    # Transmission MUST be stopped before modifying settings.json
    local service="transmission@${user}"
    local was_running=false
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        was_running=true
        service_stop_start stop "$service"
        # Give it a moment to flush and write config
        sleep 1
    fi

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would update ${config} with ${profile} profile, ${disk} disk settings"
        _show_transmission_dry_run "$profile" "$disk"
    else
        _update_transmission_json "$config" "$profile" "$disk"
        chown "${user}:${user}" "$config" 2>/dev/null || true
    fi

    if [[ "$was_running" == true ]]; then
        service_stop_start start "$service"
    fi
}

_show_transmission_dry_run() {
    local profile="$1"
    local disk="$2"
    local limits
    declare -A limits
    case "$profile" in
        light)  limits[peers]=200; limits[per]=50;  limits[slots]=8;  limits[dl]=5;  limits[seed]=10  ;;
        medium) limits[peers]=500; limits[per]=100; limits[slots]=16; limits[dl]=10; limits[seed]=25  ;;
        heavy)  limits[peers]=1000;limits[per]=200; limits[slots]=32; limits[dl]=25; limits[seed]=100 ;;
    esac
    local cache
    case "$disk" in NVME) cache=512;; SSD) cache=256;; HDD) cache=64;; *) cache=128;; esac

    echo_dry_run "  peer-limit-global=${limits[peers]}"
    echo_dry_run "  peer-limit-per-torrent=${limits[per]}"
    echo_dry_run "  upload-slots-per-torrent=${limits[slots]}"
    echo_dry_run "  cache-size-mb=${cache}"
    echo_dry_run "  download-queue-size=${limits[dl]}"
    echo_dry_run "  seed-queue-size=${limits[seed]}"
}

_update_transmission_json() {
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

# Profile-based peer and queue limits
limits = {
    "light": {
        "peer-limit-global":         200,
        "peer-limit-per-torrent":    50,
        "upload-slots-per-torrent":  8,
        "queue-stalled-minutes":     30,
        "download-queue-enabled":    True,
        "download-queue-size":       5,
        "seed-queue-enabled":        True,
        "seed-queue-size":           10,
    },
    "medium": {
        "peer-limit-global":         500,
        "peer-limit-per-torrent":    100,
        "upload-slots-per-torrent":  16,
        "queue-stalled-minutes":     15,
        "download-queue-enabled":    True,
        "download-queue-size":       10,
        "seed-queue-enabled":        True,
        "seed-queue-size":           25,
    },
    "heavy": {
        "peer-limit-global":         1000,
        "peer-limit-per-torrent":    200,
        "upload-slots-per-torrent":  32,
        "queue-stalled-minutes":     5,
        "download-queue-enabled":    True,
        "download-queue-size":       25,
        "seed-queue-enabled":        True,
        "seed-queue-size":           100,
    },
}
cfg.update(limits.get(profile, limits["medium"]))

# Disk-specific cache and preallocation
# cache-size-mb: in-memory piece cache (larger = fewer disk seeks)
disk_cache = {"NVME": 512, "SSD": 256, "HDD": 64}
cfg["cache-size-mb"] = disk_cache.get(disk, 128)

# preallocation: 0=off, 1=fast/sparse, 2=full
# Full preallocation on HDD reduces fragmentation and enables sequential I/O
if disk == "HDD":
    cfg["preallocation"] = 2
else:
    cfg["preallocation"] = 1

# Network settings tuned for seedbox use
cfg["peer-socket-tos"] = "lowcost"   # 0x02 — maximize throughput for seeding
cfg["dht-enabled"]     = True
cfg["pex-enabled"]     = True
cfg["lpd-enabled"]     = False        # disable Local Peer Discovery (DC environment)
cfg["utp-enabled"]     = True         # uTP for congestion-aware transfers

# Rename partial files (better for monitoring)
cfg["rename-partial-files"] = True

# Do not limit local bandwidth
cfg["speed-limit-down-enabled"] = False
cfg["speed-limit-up-enabled"]   = False

# Save
with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=4, sort_keys=True)

print(f"OK: updated {config_file} (profile={profile}, disk={disk})")
PYEOF
}
