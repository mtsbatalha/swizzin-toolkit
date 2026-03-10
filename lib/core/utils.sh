#!/usr/bin/env bash
# lib/core/utils.sh — Shared utilities for swizzin-toolkit
# Provides: dry_run_guard, apply_or_print, confirm_action,
#           service_stop_start, set_json_value, sed_in_place, backup_file

[[ -n "${_TOOLKIT_UTILS_LOADED:-}" ]] && return 0
_TOOLKIT_UTILS_LOADED=1

# ─── Dry-run enforcement ─────────────────────────────────────────────────────

# Central enforcement point for all state-changing operations.
# Usage:
#   dry_run_guard CMD [args...]
#   DRY_RUN=true dry_run_guard sysctl -p
#
# When DRY_RUN=true, prints a "Would: ..." message and returns 0 without
# executing anything. All tuning and backup functions MUST use this wrapper
# for every state-changing call.
dry_run_guard() {
    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would: $*"
        return 0
    fi
    "$@"
}

# Write content to a file, guarded by dry-run.
# Usage: apply_or_print "content" "/path/to/file"
apply_or_print() {
    local content="$1"
    local dest="$2"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would write to: ${dest}"
        echo_dry_run "Content preview:"
        echo "$content" | head -20 | sed 's/^/    /'
        [[ $(echo "$content" | wc -l) -gt 20 ]] && echo_dry_run "    ... (truncated)"
        return 0
    fi
    # Ensure parent directory exists
    mkdir -p "$(dirname "$dest")"
    echo "$content" > "$dest"
}

# ─── User confirmation ───────────────────────────────────────────────────────

# Prompt the user to confirm before continuing.
# Returns 0 on yes, 1 on no.
# Skipped automatically when CONFIRM_ALL=true or --yes was passed.
# Usage: confirm_action "Overwrite existing config for user alice?"
confirm_action() {
    local prompt="${1:-Continue?}"
    if [[ "${CONFIRM_ALL:-false}" == true ]]; then
        return 0
    fi
    echo_query "${prompt} [y/N]"
    local reply
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Service management ──────────────────────────────────────────────────────

# Stop or start a systemd service, dry-run aware.
# Usage: service_stop_start stop qbittorrent@alice
#        service_stop_start start qbittorrent@alice
service_stop_start() {
    local action="$1"  # stop | start | restart
    local service="$2"

    if ! systemctl list-units --full --all 2>/dev/null | grep -q "${service}"; then
        echo_warn "Service ${service} not found, skipping ${action}"
        return 0
    fi

    echo_progress_start "${action^}ing ${service}..."
    dry_run_guard systemctl "${action}" "${service}"
    echo_progress_done
}

# Wrapper: stop service, run a callback function, then restart.
# Usage: with_service_stopped "qbittorrent@alice" my_tune_func arg1 arg2
with_service_stopped() {
    local service="$1"
    shift
    local callback="$1"
    shift

    service_stop_start stop  "$service"
    "$callback" "$@"
    service_stop_start start "$service"
}

# ─── Timestamp ──────────────────────────────────────────────────────────────

make_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# ─── File backup helper ──────────────────────────────────────────────────────

# Copy a file with a timestamped suffix (used before modifying any config).
# Usage: backup_file /home/alice/.rtorrent.rc
# Returns the path of the backup copy.
backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local dest="${src}.bak.$(make_timestamp)"
    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would backup: ${src} → ${dest}"
        return 0
    fi
    cp -p "$src" "$dest"
    echo "$dest"
}

# ─── INI file setter ─────────────────────────────────────────────────────────

# Safely set a key=value in a Qt-style INI file under a specific section.
# Creates the section if it doesn't exist.
# Usage: set_ini_value "[BitTorrent]" "Session\\MaxConnections" "500" /path/to/file
set_ini_value() {
    local section="$1"
    local key="$2"
    local value="$3"
    local file="$4"

    [[ -f "$file" ]] || { echo_warn "INI file not found: $file"; return 1; }

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would set ${key}=${value} in [${section}] of ${file}"
        return 0
    fi

    # Escape special characters for use in sed regex
    local escaped_key
    escaped_key=$(printf '%s' "$key" | sed 's/[[\.*^$()+?{|]/\\&/g')
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')

    # Check if the section exists
    if ! grep -qF "$section" "$file"; then
        # Append the section and the key
        printf '\n%s\n%s=%s\n' "$section" "$key" "$value" >> "$file"
        return 0
    fi

    # Check if key already exists within the section
    if awk -v sec="$section" -v k="$key" '
        $0 == sec { in_sec=1; next }
        /^\[/ { in_sec=0 }
        in_sec && $0 ~ "^"k"=" { found=1; exit }
        END { exit !found }
    ' "$file"; then
        # Replace the existing key value (within the section only)
        awk -v sec="$section" -v k="$key" -v v="$value" '
            $0 == sec { in_sec=1; print; next }
            /^\[/ { in_sec=0 }
            in_sec && $0 ~ "^"k"=" { print k"="v; next }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        # Insert key after the section header
        awk -v sec="$section" -v k="$key" -v v="$value" '
            $0 == sec { print; print k"="v; next }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# ─── JSON file setter (via Python3) ─────────────────────────────────────────

# Set a top-level key in a JSON file using Python3.
# Usage: set_json_value /path/to/config.json "key" "value"
# For nested keys use dot notation — NOT supported here; use tune_*_user() directly.
set_json_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    [[ -f "$file" ]] || { echo_warn "JSON file not found: $file"; return 1; }

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo_dry_run "Would set ${key}=${value} in ${file}"
        return 0
    fi

    python3 - "$file" "$key" "$value" <<'PYEOF'
import json, sys

file_path, key, raw_value = sys.argv[1], sys.argv[2], sys.argv[3]

# Try to parse raw_value as a JSON literal first (true, false, null, numbers, arrays, objects)
try:
    value = json.loads(raw_value)
except json.JSONDecodeError:
    value = raw_value  # treat as plain string

with open(file_path, 'r') as f:
    data = json.load(f)

data[key] = value

with open(file_path, 'w') as f:
    json.dump(data, f, indent=4)
PYEOF
}

# ─── Root guard ──────────────────────────────────────────────────────────────

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo_error "This operation requires root privileges. Run with sudo or as root."
        exit 1
    fi
}

# ─── Sed in-place (cross-platform) ──────────────────────────────────────────

# sed -i that works on both GNU and BSD (macOS) sed.
sed_in_place() {
    if sed --version 2>&1 | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}
