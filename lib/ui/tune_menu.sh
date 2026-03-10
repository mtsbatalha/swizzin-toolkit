#!/usr/bin/env bash
# lib/ui/tune_menu.sh — Tuning sub-menus (whiptail + select fallback)

[[ -n "${_TOOLKIT_UI_TUNE_MENU_LOADED:-}" ]] && return 0
_TOOLKIT_UI_TUNE_MENU_LOADED=1

run_tune_menu() {
    if has_whiptail; then
        _tune_menu_whiptail
    else
        _tune_menu_select
    fi
}

_tune_menu_whiptail() {
    # Step 1: mode selection (auto / manual)
    local mode
    mode=$(whiptail --title "Tuning — Mode" \
        --menu "Select detection mode:" 12 60 3 \
        "auto"   "Auto-detect hardware (recommended)" \
        "manual" "Manually specify hardware parameters" \
        "status" "Show detected hardware and exit" \
        3>&1 1>&2 2>&3) || return 0

    if [[ "$mode" == "status" ]]; then
        [[ -z "${DETECTED_RAM:-}" ]] && detect_all_hardware
        display_hardware_info
        echo_query "Press Enter to continue..."; read -r _
        return 0
    fi

    if [[ "$mode" == "manual" ]]; then
        _manual_override_whiptail
    else
        [[ -z "${DETECTED_RAM:-}" ]] && detect_all_hardware
    fi

    # Show profile summary
    _show_profile_summary_whiptail

    # Step 2: target selection
    local -a checklist_items=()
    for target in kernel network disk rtorrent qbittorrent deluge transmission plex; do
        local state="OFF"
        is_app_installed "$target" 2>/dev/null && state="ON"
        [[ "$target" =~ ^(kernel|network|disk)$ ]] && state="ON"
        checklist_items+=("$target" "Tune ${target}" "$state")
    done

    local selected
    selected=$(whiptail --title "Tuning — Select Targets" \
        --checklist "Select components to tune:" 20 60 10 \
        "${checklist_items[@]}" \
        3>&1 1>&2 2>&3) || return 0

    # Clean quotes from whiptail output
    selected=$(echo "$selected" | tr -d '"')
    [[ -z "$selected" ]] && { echo_warn "No targets selected"; return 0; }

    # Step 3: dry-run option
    local dry_run_flag=""
    if whiptail --title "Dry Run?" --yesno \
        "Run in dry-run mode? (No changes will be made)" 8 50; then
        DRY_RUN=true
        dry_run_flag="--dry-run"
    fi

    echo_info "Starting tuning: ${selected}"
    run_tune "$selected"
}

_manual_override_whiptail() {
    detect_all_hardware

    local new_profile
    new_profile=$(whiptail --title "Manual Override — Profile" \
        --menu "Resource profile (detected: ${DETECTED_PROFILE}):" 12 60 3 \
        "light"  "Light  — < 4GB RAM"  \
        "medium" "Medium — 4-16GB RAM" \
        "heavy"  "Heavy  — > 16GB RAM" \
        3>&1 1>&2 2>&3) || return 0
    [[ -n "$new_profile" ]] && export OVERRIDE_PROFILE="$new_profile"

    local new_disk
    new_disk=$(whiptail --title "Manual Override — Disk Type" \
        --menu "Disk type (detected: ${DETECTED_DISK}):" 10 60 3 \
        "NVME" "NVMe SSD (fastest)" \
        "SSD"  "SATA/M.2 SSD"      \
        "HDD"  "Spinning hard disk" \
        3>&1 1>&2 2>&3) || return 0
    [[ -n "$new_disk" ]] && export OVERRIDE_DISK="$new_disk"

    local new_speed
    new_speed=$(whiptail --title "Manual Override — Network Speed" \
        --inputbox "Network link speed in Mbps (detected: ${DETECTED_NET_SPEED}):" 8 60 \
        "${DETECTED_NET_SPEED}" 3>&1 1>&2 2>&3) || return 0
    [[ -n "$new_speed" ]] && export OVERRIDE_NET_SPEED="$new_speed"
}

_show_profile_summary_whiptail() {
    local profile disk ram cpu net_speed
    profile=$(get_effective_profile)
    disk=$(get_effective_disk)
    ram=$(get_effective_ram)
    cpu=$(get_effective_cpu)
    net_speed=$(get_effective_net_speed)

    whiptail --title "Hardware Summary" --msgbox \
"Detected Hardware:
  RAM:           ${ram} GB
  CPU Cores:     ${cpu}
  Disk Type:     ${disk}
  Network Speed: ${net_speed} Mbps
  Profile:       ${profile^^}

This profile will be used for all tuning operations." 16 60
}

_tune_menu_select() {
    echo_header "Tuning"
    [[ -z "${DETECTED_RAM:-}" ]] && detect_all_hardware
    display_hardware_info

    echo "Select targets to tune (space-separated, or 'all'):"
    echo "  Options: kernel network disk rtorrent qbittorrent deluge transmission plex all"
    echo_query "Targets:"
    local targets
    read -r targets
    [[ -z "$targets" ]] && targets="all"

    echo_query "Dry-run mode? [y/N]"
    local dry
    read -r dry
    [[ "$dry" =~ ^[yY] ]] && DRY_RUN=true

    run_tune "$targets"
}
