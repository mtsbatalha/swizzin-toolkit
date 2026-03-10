#!/usr/bin/env bash
# lib/core/hardware.sh — Hardware auto-detection
# Detects RAM, CPU cores, disk type, and network speed.
# Results exported as DETECTED_* globals.
# Manual overrides stored as OVERRIDE_*; use get_effective_*() accessors everywhere.

[[ -n "${_TOOLKIT_HARDWARE_LOADED:-}" ]] && return 0
_TOOLKIT_HARDWARE_LOADED=1

# ─── Detection functions ──────────────────────────────────────────────────────

# Returns total RAM in GB (integer, rounded down)
detect_ram_gb() {
    local kb
    kb=$(awk '/MemTotal/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
    echo $(( kb / 1024 / 1024 ))
}

# Returns logical CPU core count
detect_cpu_cores() {
    nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

# Returns disk type: NVME, SSD, or HDD
# Strategy: check for NVMe devices first, then check rotational flag of root device
detect_disk_type() {
    # Check if any NVMe device exists
    if ls /dev/nvme* >/dev/null 2>&1; then
        echo "NVME"
        return
    fi

    # Find the block device backing the root filesystem
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's|/dev/||')

    # Strip partition suffix (e.g. sda1 → sda, nvme0n1p1 → nvme0n1)
    root_dev=$(echo "$root_dev" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')

    if [[ -z "$root_dev" ]]; then
        # Fallback: try lsblk
        root_dev=$(lsblk -no PKNAME "$(df / | awk 'NR==2{print $1}')" 2>/dev/null | head -1)
    fi

    local rotational_file="/sys/block/${root_dev}/queue/rotational"
    if [[ -f "$rotational_file" ]]; then
        local rot
        rot=$(cat "$rotational_file")
        if [[ "$rot" == "0" ]]; then
            echo "SSD"
        else
            echo "HDD"
        fi
        return
    fi

    # If we cannot determine, default to SSD (conservative)
    echo "SSD"
}

# Returns default network interface speed in Mbps (1000 if unknown)
detect_network_speed() {
    local iface speed

    # Find the default route interface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

    if [[ -z "$iface" ]]; then
        iface=$(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+: (eth|ens|enp|em)[^:]+/ {print $2; exit}')
    fi

    if [[ -n "$iface" ]] && [[ -f "/sys/class/net/${iface}/speed" ]]; then
        speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || echo -1)
        # speed can be -1 if the interface is down or virtual
        if [[ "$speed" -gt 0 ]] 2>/dev/null; then
            echo "$speed"
            return
        fi
    fi

    # Fallback: assume 1 Gbps
    echo 1000
}

# Returns resource profile based on RAM: light, medium, or heavy
get_profile() {
    local ram
    ram=$(get_effective_ram)
    if   [[ "$ram" -lt 4  ]]; then echo "light"
    elif [[ "$ram" -lt 16 ]]; then echo "medium"
    else                           echo "heavy"
    fi
}

# ─── Effective value accessors (respects manual overrides) ───────────────────

get_effective_ram()       { echo "${OVERRIDE_RAM:-${DETECTED_RAM:-$(detect_ram_gb)}}"; }
get_effective_cpu()       { echo "${OVERRIDE_CPU:-${DETECTED_CPU:-$(detect_cpu_cores)}}"; }
get_effective_disk()      { echo "${OVERRIDE_DISK:-${DETECTED_DISK:-$(detect_disk_type)}}"; }
get_effective_net_speed() { echo "${OVERRIDE_NET_SPEED:-${DETECTED_NET_SPEED:-$(detect_network_speed)}}"; }
get_effective_profile()   { echo "${OVERRIDE_PROFILE:-$(get_profile)}"; }

# ─── Detect and export all hardware values ───────────────────────────────────

detect_all_hardware() {
    export DETECTED_RAM;       DETECTED_RAM=$(detect_ram_gb)
    export DETECTED_CPU;       DETECTED_CPU=$(detect_cpu_cores)
    export DETECTED_DISK;      DETECTED_DISK=$(detect_disk_type)
    export DETECTED_NET_SPEED; DETECTED_NET_SPEED=$(detect_network_speed)
    export DETECTED_PROFILE;   DETECTED_PROFILE=$(get_profile)
}

# ─── Display a summary table ─────────────────────────────────────────────────

display_hardware_info() {
    # Ensure detection has run
    [[ -z "${DETECTED_RAM:-}" ]] && detect_all_hardware

    local profile
    profile=$(get_effective_profile)

    echo_header "Hardware Detection"
    printf "  %-22s %s\n" "RAM:"          "$(get_effective_ram) GB"
    printf "  %-22s %s\n" "CPU Cores:"    "$(get_effective_cpu)"
    printf "  %-22s %s\n" "Disk Type:"    "$(get_effective_disk)"
    printf "  %-22s %s Mbps\n" "Network Speed:" "$(get_effective_net_speed)"
    printf "  %-22s %s\n" "Resource Profile:" "${profile^^}"
    echo
}
