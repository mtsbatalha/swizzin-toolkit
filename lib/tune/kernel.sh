#!/usr/bin/env bash
# lib/tune/kernel.sh — Kernel sysctl parameter tuning
# Writes /etc/sysctl.d/99-swizzin-toolkit.conf and applies it.
# Called by lib/tune/tune.sh; do not call directly.

[[ -n "${_TOOLKIT_TUNE_KERNEL_LOADED:-}" ]] && return 0
_TOOLKIT_TUNE_KERNEL_LOADED=1

tune_kernel() {
    echo_header "Kernel Tuning"
    require_root

    local profile disk ram
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)
    ram=$(get_effective_ram)

    echo_info "Profile: ${profile^^} | Disk: ${disk} | RAM: ${ram}GB"

    # Back up existing sysctl conf before modifying
    if [[ -f "${TOOLKIT_SYSCTL_FILE}" ]]; then
        backup_file "${TOOLKIT_SYSCTL_FILE}"
    fi

    local content
    content=$(_build_sysctl_content "$profile" "$disk" "$ram")

    echo_progress_start "Writing ${TOOLKIT_SYSCTL_FILE}..."
    apply_or_print "$content" "${TOOLKIT_SYSCTL_FILE}"
    echo_progress_done

    echo_progress_start "Applying sysctl parameters..."
    dry_run_guard sysctl -p "${TOOLKIT_SYSCTL_FILE}"
    echo_progress_done

    echo_success "Kernel tuning complete"
}

rollback_kernel() {
    local backup_dir="$1"
    local sysctl_backup="${backup_dir}/sysctl.conf.bak"
    if [[ -f "$sysctl_backup" ]]; then
        echo_progress_start "Restoring kernel sysctl config..."
        dry_run_guard cp "$sysctl_backup" "${TOOLKIT_SYSCTL_FILE}"
        dry_run_guard sysctl -p "${TOOLKIT_SYSCTL_FILE}"
        echo_progress_done
    else
        echo_warn "No kernel backup found in ${backup_dir}"
    fi
}

# ─── Content builder ─────────────────────────────────────────────────────────

_build_sysctl_content() {
    local profile="$1"
    local disk="$2"
    local ram="$3"

    # Calculate dynamic values
    local file_max vm_dirty_ratio vm_dirty_bg_ratio vm_swappiness

    case "$profile" in
        light)
            file_max=524288
            ;;
        medium)
            file_max=1048576
            ;;
        heavy|*)
            file_max=2097152
            ;;
    esac

    # Disk-aware dirty ratios and swappiness
    case "$disk" in
        NVME)
            vm_dirty_ratio=5
            vm_dirty_bg_ratio=2
            vm_swappiness=1
            ;;
        SSD)
            vm_dirty_ratio=10
            vm_dirty_bg_ratio=5
            vm_swappiness=10
            ;;
        HDD|*)
            vm_dirty_ratio=20
            vm_dirty_bg_ratio=10
            vm_swappiness=30
            ;;
    esac

    cat <<EOF
# swizzin-toolkit — kernel tuning
# Generated: $(date)
# Profile: ${profile} | Disk: ${disk} | RAM: ${ram}GB
# DO NOT EDIT MANUALLY — managed by swizzin-toolkit

# ─── File descriptors ─────────────────────────────────────────────────────────
fs.file-max = ${file_max}
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# ─── Virtual memory ───────────────────────────────────────────────────────────
vm.swappiness = ${vm_swappiness}
vm.dirty_ratio = ${vm_dirty_ratio}
vm.dirty_background_ratio = ${vm_dirty_bg_ratio}
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1

# ─── Kernel misc ──────────────────────────────────────────────────────────────
kernel.pid_max = 4194304
kernel.dmesg_restrict = 0
EOF
}
