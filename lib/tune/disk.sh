#!/usr/bin/env bash
# lib/tune/disk.sh — Disk I/O scheduler and readahead tuning
# Sets the I/O scheduler and readahead for all relevant block devices,
# persisted via a udev rule.
#
# Scheduler choices:
#   NVMe → none        (no queuing benefit; NVMe handles its own queue)
#   SSD  → mq-deadline (low latency, ordered, no starvation)
#   HDD  → bfq         (Budget Fair Queueing; best for mixed workloads)
#
# Readahead (in 512-byte sectors):
#   NVMe → 256   (~128 KB)
#   SSD  → 512   (~256 KB)
#   HDD  → 2048  (~1 MB)

[[ -n "${_TOOLKIT_TUNE_DISK_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_DISK_LOADED=1

tune_disk() {
    echo_header "Disk I/O Tuning"
    require_root

    local disk
    disk=$(get_effective_disk)
    echo_info "Detected disk type: ${disk}"

    local scheduler readahead
    case "$disk" in
        NVME) scheduler="none";        readahead=256  ;;
        SSD)  scheduler="mq-deadline"; readahead=512  ;;
        HDD)  scheduler="bfq";         readahead=2048 ;;
        *)    scheduler="mq-deadline"; readahead=512  ;;
    esac

    echo_info "Scheduler: ${scheduler} | Readahead: $((readahead / 2)) KB"

    local devices
    mapfile -t devices < <(_get_relevant_block_devices)

    if [[ ${#devices[@]} -eq 0 ]]; then
        echo_warn "No block devices found to tune"
        return 0
    fi

    local udev_rules=""
    for dev in "${devices[@]}"; do
        echo_progress_start "Tuning /dev/${dev}..."
        _apply_disk_settings "$dev" "$scheduler" "$readahead"
        udev_rules+=$(_build_udev_rule "$dev" "$scheduler" "$readahead")
        echo_progress_done
    done

    # Write persistent udev rule
    echo_progress_start "Writing udev rule for persistence..."
    apply_or_print "$(_build_udev_file "$udev_rules")" "${TOOLKIT_UDEV_RULE}"
    echo_progress_done

    # Reload udev rules
    echo_progress_start "Reloading udev..."
    dry_run_guard udevadm control --reload-rules
    dry_run_guard udevadm trigger --type=devices --action=add
    echo_progress_done

    echo_success "Disk I/O tuning complete"
}

rollback_disk() {
    echo_progress_start "Removing toolkit udev rule..."
    if [[ -f "${TOOLKIT_UDEV_RULE}" ]]; then
        dry_run_guard rm -f "${TOOLKIT_UDEV_RULE}"
        dry_run_guard udevadm control --reload-rules
        echo_progress_done "udev rule removed (system defaults restored on next boot)"
    else
        echo_warn "No disk tuning rule found at ${TOOLKIT_UDEV_RULE}"
    fi
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# List physical block devices (not partitions, not loop/ram devices)
_get_relevant_block_devices() {
    local devs=()
    for dev in /sys/block/*; do
        local name
        name=$(basename "$dev")

        # Skip loop, ram, zram, dm devices
        [[ "$name" =~ ^(loop|ram|zram|dm-) ]] && continue

        # Skip if it has no queue directory (virtual device)
        [[ -d "${dev}/queue" ]] || continue

        devs+=("$name")
    done
    printf '%s\n' "${devs[@]}"
}

_get_current_scheduler() {
    local dev="$1"
    local sched_file="/sys/block/${dev}/queue/scheduler"
    [[ -f "$sched_file" ]] || { echo "unknown"; return; }
    # Current scheduler is in brackets: [mq-deadline] kyber bfq none
    grep -oP '\[\K[^\]]+' "$sched_file" 2>/dev/null || cat "$sched_file"
}

_apply_disk_settings() {
    local dev="$1"
    local scheduler="$2"
    local readahead="$3"

    local sched_file="/sys/block/${dev}/queue/scheduler"
    local ra_file="/sys/block/${dev}/queue/read_ahead_kb"

    # Set I/O scheduler
    if [[ -f "$sched_file" ]]; then
        if grep -q "$scheduler" "$sched_file" 2>/dev/null; then
            dry_run_guard bash -c "echo '${scheduler}' > '${sched_file}'"
        else
            echo_warn "Scheduler '${scheduler}' not available for ${dev}, available: $(cat "$sched_file" 2>/dev/null)"
        fi
    fi

    # Set readahead (blockdev takes KB, sysfs also uses KB but different file)
    if [[ -f "$ra_file" ]]; then
        local ra_kb=$(( readahead / 2 ))  # convert 512-byte sectors to KB
        dry_run_guard bash -c "echo '${ra_kb}' > '${ra_file}'"
    else
        dry_run_guard blockdev --setra "$readahead" "/dev/${dev}" 2>/dev/null || true
    fi
}

_build_udev_rule() {
    local dev="$1"
    local scheduler="$2"
    local readahead="$3"
    local ra_kb=$(( readahead / 2 ))

    # Identify by kernel name (KERNEL=="sda") for simplicity
    # For production, ATTR{wwid} would be more robust
    cat <<EOF
# Device: ${dev}
ACTION=="add|change", KERNEL=="${dev}", ATTR{queue/scheduler}="${scheduler}", ATTR{queue/read_ahead_kb}="${ra_kb}"
EOF
}

_build_udev_file() {
    local rules="$1"
    cat <<EOF
# swizzin-toolkit — disk I/O scheduler rules
# Generated: $(date)
# DO NOT EDIT MANUALLY — managed by swizzin-toolkit
# To remove: toolkit rollback disk

${rules}
EOF
}
