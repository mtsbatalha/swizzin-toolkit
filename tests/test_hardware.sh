#!/usr/bin/env bash
# tests/test_hardware.sh — Hardware detection unit tests

run_hardware_tests() {
    _section "Hardware Detection"

    # ── detect_ram_gb ──
    local ram
    ram=$(detect_ram_gb)
    assert_not_empty "detect_ram_gb returns a value" "$ram"
    if [[ "$ram" -gt 0 ]] 2>/dev/null; then
        _pass "detect_ram_gb returns positive integer"
    else
        _fail "detect_ram_gb returns positive integer" "got: ${ram}"
    fi

    # ── detect_cpu_cores ──
    local cpu
    cpu=$(detect_cpu_cores)
    assert_not_empty "detect_cpu_cores returns a value" "$cpu"
    if [[ "$cpu" -gt 0 ]] 2>/dev/null; then
        _pass "detect_cpu_cores returns positive integer"
    else
        _fail "detect_cpu_cores returns positive integer" "got: ${cpu}"
    fi

    # ── detect_disk_type ──
    local disk
    disk=$(detect_disk_type)
    assert_not_empty "detect_disk_type returns a value" "$disk"
    if [[ "$disk" =~ ^(NVME|SSD|HDD)$ ]]; then
        _pass "detect_disk_type returns valid value (got: ${disk})"
    else
        _fail "detect_disk_type returns valid value" "got: ${disk}"
    fi

    # ── detect_network_speed ──
    local net
    net=$(detect_network_speed)
    assert_not_empty "detect_network_speed returns a value" "$net"
    if [[ "$net" -gt 0 ]] 2>/dev/null; then
        _pass "detect_network_speed returns positive integer"
    else
        _fail "detect_network_speed returns positive integer" "got: ${net}"
    fi

    # ── get_profile ──
    # Test with injected OVERRIDE_RAM values
    OVERRIDE_RAM=2 assert_eq "Profile is 'light' for 2GB RAM" "light" "$(get_profile)"
    OVERRIDE_RAM=8 assert_eq "Profile is 'medium' for 8GB RAM" "medium" "$(get_profile)"
    OVERRIDE_RAM=32 assert_eq "Profile is 'heavy' for 32GB RAM" "heavy" "$(get_profile)"
    unset OVERRIDE_RAM

    # ── Manual overrides ──
    export OVERRIDE_RAM=16
    assert_eq "OVERRIDE_RAM is used by get_effective_ram" "16" "$(get_effective_ram)"
    unset OVERRIDE_RAM

    export OVERRIDE_DISK="NVME"
    assert_eq "OVERRIDE_DISK is used by get_effective_disk" "NVME" "$(get_effective_disk)"
    unset OVERRIDE_DISK

    # ── detect_all_hardware ──
    detect_all_hardware
    assert_not_empty "DETECTED_RAM is exported after detect_all_hardware" "${DETECTED_RAM:-}"
    assert_not_empty "DETECTED_CPU is exported after detect_all_hardware" "${DETECTED_CPU:-}"
    assert_not_empty "DETECTED_DISK is exported after detect_all_hardware" "${DETECTED_DISK:-}"
    assert_not_empty "DETECTED_NET_SPEED is exported after detect_all_hardware" "${DETECTED_NET_SPEED:-}"
    assert_not_empty "DETECTED_PROFILE is exported after detect_all_hardware" "${DETECTED_PROFILE:-}"
}
