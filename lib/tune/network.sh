#!/usr/bin/env bash
# lib/tune/network.sh — Network stack tuning
# Adaptive to both RAM profile AND detected link speed.
# Enables BBR congestion control when kernel supports it.

[[ -n "${_TOOLKIT_TUNE_NETWORK_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_NETWORK_LOADED=1

tune_network() {
    echo_header "Network Tuning"
    require_root

    local profile disk ram net_speed
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)
    ram=$(get_effective_ram)
    net_speed=$(get_effective_net_speed)

    echo_info "Profile: ${profile^^} | Link: ${net_speed}Mbps"

    # Back up existing config if present
    if [[ -f "${TOOLKIT_SYSCTL_FILE}" ]]; then
        backup_file "${TOOLKIT_SYSCTL_FILE}"
    fi

    local content
    content=$(_build_network_sysctl "$profile" "$ram" "$net_speed")

    # Append to sysctl file (kernel.sh creates the base; network appends to same file)
    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would append network settings to ${TOOLKIT_SYSCTL_FILE}"
        echo "$content" | head -30 | sed 's/^/    /'
    else
        mkdir -p "$(dirname "${TOOLKIT_SYSCTL_FILE}")"
        echo "$content" >> "${TOOLKIT_SYSCTL_FILE}"
    fi

    # Enable BBR if supported
    _enable_bbr

    echo_progress_start "Applying network sysctl parameters..."
    dry_run_guard sysctl -p "${TOOLKIT_SYSCTL_FILE}"
    echo_progress_done

    echo_success "Network tuning complete"
}

# ─── BBR ─────────────────────────────────────────────────────────────────────

_enable_bbr() {
    local kernel_ver
    kernel_ver=$(uname -r | awk -F. '{print $1*100+$2}')
    if [[ "$kernel_ver" -lt 409 ]]; then
        echo_warn "Kernel < 4.9 — BBR not supported, skipping"
        return 0
    fi

    echo_progress_start "Enabling BBR congestion control..."
    dry_run_guard modprobe tcp_bbr 2>/dev/null || true

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would set net.core.default_qdisc=fq"
        echo_dry_run "Would set net.ipv4.tcp_congestion_control=bbr"
    else
        # Only set if BBR is available
        if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
            # Persist in sysctl file
            {
                echo ""
                echo "# BBR congestion control"
                echo "net.core.default_qdisc = fq"
                echo "net.ipv4.tcp_congestion_control = bbr"
            } >> "${TOOLKIT_SYSCTL_FILE}"
            echo_progress_done "BBR enabled"
        else
            echo_warn "BBR module loaded but not available — kernel may not support it"
        fi
    fi
}

# ─── Buffer size calculation ─────────────────────────────────────────────────
# Combines RAM profile AND link speed for optimal buffer sizing.
# Higher link speed needs larger buffers to maintain throughput.

_calculate_buffers() {
    local ram="$1"
    local net_speed="$2"  # Mbps

    # BDP (Bandwidth-Delay Product) estimate for 50ms RTT:
    # BDP = link_speed_bytes * RTT = (net_speed * 1000000 / 8) * 0.05
    local bdp_bytes=$(( net_speed * 1000000 / 8 * 50 / 1000 ))

    # Buffer = max(BDP * 2, profile minimum)
    local min_by_profile
    case "$ram" in
        [0-3])  min_by_profile=$(( 16 * 1024 * 1024 )) ;;   # 16 MB
        [4-9]|1[0-5]) min_by_profile=$(( 64 * 1024 * 1024 )) ;;  # 64 MB
        *)      min_by_profile=$(( 128 * 1024 * 1024 )) ;;  # 128 MB
    esac

    local desired=$(( bdp_bytes * 2 ))
    local max_by_ram=$(( ram * 1024 * 1024 * 1024 / 16 ))  # cap at RAM/16

    # Use max of BDP-based and profile minimum, but not more than RAM/16
    local result
    result=$(( desired > min_by_profile ? desired : min_by_profile ))
    result=$(( result < max_by_ram ? result : max_by_ram ))

    # Cap absolute maximum at 256MB to avoid extreme values
    local abs_max=$(( 256 * 1024 * 1024 ))
    result=$(( result < abs_max ? result : abs_max ))

    echo "$result"
}

_build_network_sysctl() {
    local profile="$1"
    local ram="$2"
    local net_speed="$3"

    local rmem_max wmem_max
    rmem_max=$(_calculate_buffers "$ram" "$net_speed")
    wmem_max=$rmem_max

    local rmem_default=$(( rmem_max / 4 ))
    local wmem_default=$(( wmem_max / 4 ))

    # TCP socket buffer: min, default, max
    local tcp_rmem="4096 ${rmem_default} ${rmem_max}"
    local tcp_wmem="4096 ${wmem_default} ${wmem_max}"

    # Connection limits by profile
    local somaxconn netdev_backlog tcp_max_syn_backlog port_range_start
    case "$profile" in
        light)
            somaxconn=4096
            netdev_backlog=4096
            tcp_max_syn_backlog=4096
            port_range_start=1024
            ;;
        medium)
            somaxconn=16384
            netdev_backlog=16384
            tcp_max_syn_backlog=8192
            port_range_start=1024
            ;;
        heavy|*)
            somaxconn=65535
            netdev_backlog=65536
            tcp_max_syn_backlog=65536
            port_range_start=1024
            ;;
    esac

    cat <<EOF

# ─── Network stack (swizzin-toolkit) ─────────────────────────────────────────
# Link speed: ${net_speed} Mbps | Profile: ${profile}

# Socket buffers (adaptive to RAM + link speed)
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.rmem_default = ${rmem_default}
net.core.wmem_default = ${wmem_default}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}

# UDP buffers (useful for BitTorrent uTP)
net.core.netdev_max_backlog = ${netdev_backlog}

# Connection management
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${tcp_max_syn_backlog}
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# TCP performance features
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Port range (allow more ephemeral ports for outbound connections)
net.ipv4.ip_local_port_range = ${port_range_start} 65535

# IP forwarding (disabled for seedboxes)
net.ipv4.ip_forward = 0
EOF
}
