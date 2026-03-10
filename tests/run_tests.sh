#!/usr/bin/env bash
# tests/run_tests.sh — Test runner for swizzin-toolkit
#
# Usage: bash tests/run_tests.sh [--verbose]
#
# All tests use DRY_RUN=true and mock environments.
# Safe to run as root or non-root on any system.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(dirname "$TESTS_DIR")"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
VERBOSE="${1:-}"

# ─── Test framework ──────────────────────────────────────────────────────────

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected='${expected}' actual='${actual}'"
    fi
}

assert_not_empty() {
    local desc="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "value was empty"
    fi
}

assert_file_exists() {
    local desc="$1" file="$2"
    if [[ -f "$file" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "file not found: ${file}"
    fi
}

assert_file_not_modified() {
    local desc="$1" before_hash="$2" file="$3"
    local after_hash
    after_hash=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1 || echo "MISSING")
    if [[ "$before_hash" == "$after_hash" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "file was modified: ${file}"
    fi
}

assert_dir_exists() {
    local desc="$1" dir="$2"
    if [[ -d "$dir" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "directory not found: ${dir}"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle"; then
        _pass "$desc"
    else
        _fail "$desc" "'${needle}' not found in output"
    fi
}

skip_test() {
    local desc="$1" reason="${2:-}"
    printf "  [SKIP] %s%s\n" "$desc" "${reason:+ ($reason)}"
    (( SKIP_COUNT++ ))
}

_pass() {
    printf "  [PASS] %s\n" "$1"
    (( PASS_COUNT++ ))
}

_fail() {
    printf "  [FAIL] %s — %s\n" "$1" "${2:-}" >&2
    (( FAIL_COUNT++ ))
}

_section() {
    printf "\n── %s ──\n" "$1"
}

# ─── Load toolkit (in dry-run mode) ─────────────────────────────────────────

export DRY_RUN=true
export CONFIRM_ALL=true
export TOOLKIT_LOG="/dev/null"
export TOOLKIT_SYSCTL_FILE="/tmp/test-sysctl-$(date +%N).conf"
export TOOLKIT_UDEV_RULE="/tmp/test-udev-$(date +%N).rules"
export TOOLKIT_BACKUP_ROOT="/tmp/toolkit-test-backups-$(date +%N)"
export TOOLKIT_TUNE_BACKUP_ROOT="${TOOLKIT_BACKUP_ROOT}/.tuning"
export TOOLKIT_PLEX_OVERRIDE_DIR="/tmp/test-plex-override-$(date +%N)"
export TOOLKIT_PLEX_OVERRIDE_FILE="swizzin-toolkit.conf"

# Source core libraries (not the full toolkit to avoid root check triggering)
# shellcheck source=conf/defaults.conf
source "${TOOLKIT_ROOT}/conf/defaults.conf"
# shellcheck source=lib/core/colors.sh
source "${TOOLKIT_ROOT}/lib/core/colors.sh"
# shellcheck source=lib/core/hardware.sh
source "${TOOLKIT_ROOT}/lib/core/hardware.sh"
# shellcheck source=lib/core/swizzin.sh
source "${TOOLKIT_ROOT}/lib/core/swizzin.sh"
# shellcheck source=lib/core/utils.sh
source "${TOOLKIT_ROOT}/lib/core/utils.sh"

# ─── Load test suites ────────────────────────────────────────────────────────

# shellcheck source=tests/test_hardware.sh
source "${TESTS_DIR}/test_hardware.sh"
# shellcheck source=tests/test_swizzin.sh
source "${TESTS_DIR}/test_swizzin.sh"
# shellcheck source=tests/test_tune_dry_run.sh
source "${TESTS_DIR}/test_tune_dry_run.sh"
# shellcheck source=tests/test_backup.sh
source "${TESTS_DIR}/test_backup.sh"

# ─── Run all tests ───────────────────────────────────────────────────────────

echo "====================================================="
echo "  swizzin-toolkit test suite"
echo "====================================================="

run_hardware_tests
run_swizzin_tests
run_tune_dry_run_tests
run_backup_tests

echo
echo "====================================================="
printf "  Results: %d passed, %d failed, %d skipped\n" \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "====================================================="

[[ $FAIL_COUNT -eq 0 ]]
