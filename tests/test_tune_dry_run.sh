#!/usr/bin/env bash
# tests/test_tune_dry_run.sh — Verify tuning modules make NO changes with DRY_RUN=true
# All functions that touch disk/sysctl/systemd must go through dry_run_guard.

# Source tune modules for testing
_load_tune_modules() {
    source "${TOOLKIT_ROOT}/lib/tune/kernel.sh"
    source "${TOOLKIT_ROOT}/lib/tune/network.sh"
    source "${TOOLKIT_ROOT}/lib/tune/disk.sh"
    source "${TOOLKIT_ROOT}/lib/tune/rtorrent.sh"
    source "${TOOLKIT_ROOT}/lib/tune/qbittorrent.sh"
    source "${TOOLKIT_ROOT}/lib/tune/deluge.sh"
    source "${TOOLKIT_ROOT}/lib/tune/transmission.sh"
    source "${TOOLKIT_ROOT}/lib/tune/plex.sh"
}

run_tune_dry_run_tests() {
    _section "Tuning Dry-Run"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # Ensure DRY_RUN is set
    export DRY_RUN=true
    export OVERRIDE_RAM=4
    export OVERRIDE_CPU=4
    export OVERRIDE_DISK=SSD
    export OVERRIDE_NET_SPEED=1000

    _load_tune_modules 2>/dev/null || { _fail "tune modules load" "source failed"; return; }

    # ── kernel.sh: no file should be written ──
    local sysctl_test="/tmp/test-sysctl-$(date +%N).conf"
    export TOOLKIT_SYSCTL_FILE="$sysctl_test"
    tune_kernel 2>/dev/null || true
    if [[ ! -f "$sysctl_test" ]]; then
        _pass "tune_kernel: sysctl file not written in dry-run"
    else
        _fail "tune_kernel: sysctl file not written in dry-run" "${sysctl_test} was created"
        rm -f "$sysctl_test"
    fi

    # ── disk.sh: no udev rule should be written ──
    local udev_test="/tmp/test-udev-$(date +%N).rules"
    export TOOLKIT_UDEV_RULE="$udev_test"
    tune_disk 2>/dev/null || true
    if [[ ! -f "$udev_test" ]]; then
        _pass "tune_disk: udev rule not written in dry-run"
    else
        _fail "tune_disk: udev rule not written in dry-run" "${udev_test} was created"
        rm -f "$udev_test"
    fi

    # ── rtorrent.sh: config not modified ──
    local rt_home="${tmp}/home/testuser"
    mkdir -p "$rt_home"
    echo "max_peers.normal = 40" > "${rt_home}/.rtorrent.rc"
    local before_hash
    before_hash=$(md5sum "${rt_home}/.rtorrent.rc" | cut -d' ' -f1)

    # Mock get_all_users to return our test user
    get_all_users() { echo "testuser"; }
    # Override home path resolution by making it absolute
    # (tune_rtorrent_user uses /home/$user, so we need the real path)
    # Just test the internal function directly with our path
    tune_rtorrent_user "testuser" "${rt_home}/.rtorrent.rc" 2>/dev/null || true
    unset -f get_all_users

    assert_file_not_modified "tune_rtorrent_user: rc file not modified in dry-run" \
        "$before_hash" "${rt_home}/.rtorrent.rc"

    # ── qbittorrent.sh: config not modified ──
    mkdir -p "${tmp}/home/testuser/.config/qBittorrent"
    cat > "${tmp}/home/testuser/.config/qBittorrent/qBittorrent.conf" <<'EOF'
[BitTorrent]
Session\MaxConnections=100
EOF
    local qbt_conf="${tmp}/home/testuser/.config/qBittorrent/qBittorrent.conf"
    local before_hash_qbt
    before_hash_qbt=$(md5sum "$qbt_conf" | cut -d' ' -f1)
    tune_qbittorrent_user "testuser" "$qbt_conf" 2>/dev/null || true
    assert_file_not_modified "tune_qbittorrent_user: conf not modified in dry-run" \
        "$before_hash_qbt" "$qbt_conf"

    # ── deluge.sh: config not modified ──
    if command -v python3 >/dev/null 2>&1; then
        mkdir -p "${tmp}/home/testuser/.config/deluge"
        echo '{"max_connections_global": 200}' > "${tmp}/home/testuser/.config/deluge/core.conf"
        local deluge_conf="${tmp}/home/testuser/.config/deluge/core.conf"
        local before_hash_deluge
        before_hash_deluge=$(md5sum "$deluge_conf" | cut -d' ' -f1)
        tune_deluge_user "testuser" "$deluge_conf" 2>/dev/null || true
        assert_file_not_modified "tune_deluge_user: core.conf not modified in dry-run" \
            "$before_hash_deluge" "$deluge_conf"
    else
        skip_test "tune_deluge dry-run" "python3 not available"
    fi

    # ── transmission.sh: config not modified ──
    if command -v python3 >/dev/null 2>&1; then
        mkdir -p "${tmp}/home/testuser/.config/transmission-daemon"
        echo '{"peer-limit-global": 200}' \
            > "${tmp}/home/testuser/.config/transmission-daemon/settings.json"
        local trans_conf="${tmp}/home/testuser/.config/transmission-daemon/settings.json"
        local before_hash_trans
        before_hash_trans=$(md5sum "$trans_conf" | cut -d' ' -f1)
        tune_transmission_user "testuser" "$trans_conf" 2>/dev/null || true
        assert_file_not_modified "tune_transmission_user: settings.json not modified in dry-run" \
            "$before_hash_trans" "$trans_conf"
    else
        skip_test "tune_transmission dry-run" "python3 not available"
    fi

    # ── plex.sh: no override written ──
    local plex_override_dir="${tmp}/plex-override"
    export TOOLKIT_PLEX_OVERRIDE_DIR="$plex_override_dir"
    # Mock is_app_installed to return true for plex
    is_app_installed() { [[ "$1" == "plex" ]]; }
    tune_plex 2>/dev/null || true
    unset -f is_app_installed
    if [[ ! -f "${plex_override_dir}/swizzin-toolkit.conf" ]]; then
        _pass "tune_plex: systemd override not written in dry-run"
    else
        _fail "tune_plex: systemd override not written in dry-run"
    fi

    unset OVERRIDE_RAM OVERRIDE_CPU OVERRIDE_DISK OVERRIDE_NET_SPEED
}
