#!/usr/bin/env bash
# lib/tune/plex.sh — Plex Media Server performance tuning via systemd override

[[ -n "${_TOOLKIT_TUNE_PLEX_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_PLEX_LOADED=1

tune_plex() {
    echo_header "Plex Media Server Tuning"

    if ! is_app_installed plex; then
        echo_warn "Plex Media Server is not installed — skipping"
        return 0
    fi

    local profile disk cpu
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)
    cpu=$(get_effective_cpu)

    echo_info "Profile: ${profile^^} | Disk: ${disk} | CPU cores: ${cpu}"

    # Container detection (affects CPUSchedulingPolicy)
    local is_container=false
    if [[ -f /run/systemd/container ]] \
        || grep -qE '(docker|lxc|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
        is_container=true
        echo_info "Container environment detected — some settings adjusted"
    fi

    # Calculate memory limit
    local mem_limit
    case "$profile" in
        light)  mem_limit="2G"  ;;
        medium) mem_limit="4G"  ;;
        heavy)  mem_limit="8G"  ;;
    esac

    # Transcoder threads = min(cpu_cores, 16)
    local transcoder_threads
    transcoder_threads=$(( cpu < 16 ? cpu : 16 ))

    # I/O buffer size
    local io_buf_size
    case "$disk" in
        NVME|SSD) io_buf_size="2MB" ;;
        HDD)      io_buf_size="1MB" ;;
        *)        io_buf_size="1MB" ;;
    esac

    local override_dir="${TOOLKIT_PLEX_OVERRIDE_DIR}"
    local override_file="${override_dir}/${TOOLKIT_PLEX_OVERRIDE_FILE}"

    local content
    content=$(_build_plex_override "$mem_limit" "$transcoder_threads" "$is_container")

    echo_progress_start "Writing systemd override: ${override_file}..."
    dry_run_guard mkdir -p "$override_dir"
    apply_or_print "$content" "$override_file"
    echo_progress_done

    echo_progress_start "Reloading systemd daemon..."
    dry_run_guard systemctl daemon-reload
    echo_progress_done

    echo_progress_start "Restarting plexmediaserver..."
    dry_run_guard systemctl restart plexmediaserver
    echo_progress_done

    echo_success "Plex tuned (${transcoder_threads} transcoder threads, ${mem_limit} memory limit)"
}

rollback_plex() {
    local override_file="${TOOLKIT_PLEX_OVERRIDE_DIR}/${TOOLKIT_PLEX_OVERRIDE_FILE}"
    echo_progress_start "Removing Plex systemd override..."
    if [[ -f "$override_file" ]]; then
        dry_run_guard rm -f "$override_file"
        dry_run_guard systemctl daemon-reload
        dry_run_guard systemctl restart plexmediaserver
        echo_progress_done "Override removed, Plex restarted with default settings"
    else
        echo_warn "No Plex override found at ${override_file}"
    fi
}

_build_plex_override() {
    local mem_limit="$1"
    local transcoder_threads="$2"
    local is_container="$3"

    cat <<EOF
# swizzin-toolkit — Plex Media Server performance override
# Generated: $(date)
# DO NOT EDIT MANUALLY — managed by swizzin-toolkit

[Service]
# Process priority (lower nice value = higher priority)
Nice=-5

# I/O scheduling
IOSchedulingClass=best-effort
IOSchedulingPriority=2
EOF

    # CPUSchedulingPolicy is not available inside containers
    if [[ "$is_container" != "true" ]]; then
        echo "CPUSchedulingPolicy=other"
    fi

    cat <<EOF

# Memory limit
MemoryMax=${mem_limit}
MemorySwapMax=0

# Transcoder thread count
Environment=MYPLEX_TRANSCODER_THREADS=${transcoder_threads}
Environment=PLEX_MEDIA_SERVER_MAX_PLUGIN_PROCS=6

# File descriptor limit for large libraries
LimitNOFILE=1048576
EOF
}
