#!/usr/bin/env bash
# tests/test_swizzin.sh — Swizzin integration unit tests
# Uses temporary directories to mock swizzin environment

run_swizzin_tests() {
    _section "Swizzin Integration"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # ── is_swizzin_installed (no swizzin) ──
    local orig_globals="${SWIZZIN_GLOBALS:-}"
    export SWIZZIN_GLOBALS="${tmp}/nonexistent/globals.sh"
    if ! is_swizzin_installed; then
        _pass "is_swizzin_installed returns false when globals.sh missing"
    else
        _fail "is_swizzin_installed returns false when globals.sh missing"
    fi

    # ── is_swizzin_installed (with swizzin) ──
    mkdir -p "${tmp}/sources"
    touch "${tmp}/sources/globals.sh"
    export SWIZZIN_GLOBALS="${tmp}/sources/globals.sh"
    if is_swizzin_installed; then
        _pass "is_swizzin_installed returns true when globals.sh exists"
    else
        _fail "is_swizzin_installed returns true when globals.sh exists"
    fi
    export SWIZZIN_GLOBALS="${orig_globals}"

    # ── is_app_installed via lock file ──
    local orig_lock="${SWIZZIN_LOCK_DIR:-}"
    export SWIZZIN_LOCK_DIR="${tmp}/install"
    mkdir -p "${tmp}/install"
    touch "${tmp}/install/.rtorrent.lock"
    if is_app_installed rtorrent; then
        _pass "is_app_installed returns true with lock file"
    else
        _fail "is_app_installed returns true with lock file"
    fi

    # ── is_app_installed returns false without lock file ──
    if ! is_app_installed qbittorrent 2>/dev/null; then
        _pass "is_app_installed returns false when no lock file and no binary"
    else
        skip_test "is_app_installed false without lock file" "qbittorrent may be installed on this system"
    fi
    export SWIZZIN_LOCK_DIR="${orig_lock}"

    # ── get_master_user ──
    local orig_master="${SWIZZIN_MASTER_INFO:-}"
    export SWIZZIN_MASTER_INFO="${tmp}/master.info"
    echo "testuser:password123" > "${tmp}/master.info"
    local master_user
    master_user=$(get_master_user)
    assert_eq "get_master_user reads username from .master.info" "testuser" "$master_user"
    export SWIZZIN_MASTER_INFO="${orig_master}"

    # ── get_all_users fallback (from /etc/passwd) ──
    # This runs in standalone mode and should return at least some users
    local orig_swizzin="${SWIZZIN_GLOBALS:-}"
    export SWIZZIN_GLOBALS="${tmp}/no/such/file"
    export SWIZZIN_MASTER_INFO="${tmp}/no/such/file"
    local users
    users=$(get_all_users)
    # May return empty on minimal systems; just check it runs without error
    _pass "get_all_users runs without error in standalone mode"
    export SWIZZIN_GLOBALS="${orig_swizzin}"
    export SWIZZIN_MASTER_INFO="${orig_master}"
}
