#!/usr/bin/env bash
# lib/backup/engine.sh — Backup session management, manifest, retention, and restore

[[ -n "${_TOOLKIT_BACKUP_ENGINE_LOADED:-}" ]] && return 0
_TOOLKIT_BACKUP_ENGINE_LOADED=1

# ─── Session management ──────────────────────────────────────────────────────

# Create a new backup session directory and return its path
create_backup_session() {
    local timestamp
    timestamp=$(make_timestamp)
    local session_dir="${TOOLKIT_BACKUP_ROOT}/${timestamp}"
    mkdir -p "$session_dir"
    echo "$session_dir"
}

# Write a JSON manifest file summarising what was backed up in a session
# Usage: write_manifest SESSION_DIR ARCHIVES_JSON_ARRAY
write_manifest() {
    local session_dir="$1"
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "unknown")
    local swizzin_installed=false
    is_swizzin_installed && swizzin_installed=true

    python3 - "$session_dir" "$hostname" "$swizzin_installed" <<'PYEOF'
import json, sys, os, glob

session_dir, hostname, swizzin_installed = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
timestamp = os.path.basename(session_dir)
archives = []

for f in glob.glob(os.path.join(session_dir, "*.tar.gz")):
    fname = os.path.basename(f)
    parts = fname.replace(".tar.gz", "").rsplit("_", 1)
    app  = parts[0] if len(parts) == 2 else fname
    user = parts[1] if len(parts) == 2 else "system"
    archives.append({
        "app":        app,
        "user":       user,
        "file":       fname,
        "size_bytes": os.path.getsize(f),
    })

manifest = {
    "timestamp":          timestamp,
    "hostname":           hostname,
    "swizzin_installed":  swizzin_installed,
    "archives":           archives,
}

with open(os.path.join(session_dir, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)

print("OK: manifest written")
PYEOF
}

# Verify archive integrity before restoring
# Returns 0 if valid, 1 if corrupt
verify_archive() {
    local archive="$1"
    if [[ ! -f "$archive" ]]; then
        echo_error "Archive not found: ${archive}"
        return 1
    fi
    tar -tzf "$archive" >/dev/null 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo_error "Archive is corrupt or invalid: ${archive}"
    fi
    return $rc
}

# ─── Backup all ──────────────────────────────────────────────────────────────

# Source path for per-app modules
_BACKUP_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run a full backup for the specified apps and users
# Usage: run_backup [--target all|rtorrent|...] [--user USER]
run_backup() {
    local targets_input="all"
    local user_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) targets_input="$2"; shift 2 ;;
            --user)   user_filter="$2";   shift 2 ;;
            *)        shift ;;
        esac
    done

    require_root

    local -a targets
    if [[ "$targets_input" == "all" ]]; then
        targets=(rtorrent qbittorrent deluge transmission plex)
    else
        IFS=', ' read -r -a targets <<< "$targets_input"
    fi

    echo_header "Backup"

    local session_dir
    session_dir=$(create_backup_session)
    echo_info "Session: $(basename "$session_dir")"
    echo_info "Location: ${session_dir}"
    echo

    # Load per-app backup modules
    for mod in rtorrent qbittorrent deluge transmission plex; do
        # shellcheck disable=SC1090
        source "${_BACKUP_MODULE_DIR}/${mod}.sh" 2>/dev/null || true
    done

    local total_archives=0
    for target in "${targets[@]}"; do
        case "$target" in
            rtorrent)     backup_rtorrent_all     "$session_dir" "$user_filter"; total_archives+=$? ;;
            qbittorrent)  backup_qbittorrent_all  "$session_dir" "$user_filter" ;;
            deluge)       backup_deluge_all        "$session_dir" "$user_filter" ;;
            transmission) backup_transmission_all  "$session_dir" "$user_filter" ;;
            plex)         backup_plex              "$session_dir"               ;;
            *)            echo_warn "Unknown backup target: ${target}"          ;;
        esac
    done

    write_manifest "$session_dir"
    enforce_retention

    echo
    echo_success "Backup complete: ${session_dir}"
    echo_info "To list all backups: toolkit list"
    echo_info "To restore: toolkit restore"
}

# ─── List backups ─────────────────────────────────────────────────────────────

list_backups() {
    local app_filter="${1:-}"

    if [[ ! -d "${TOOLKIT_BACKUP_ROOT}" ]] || [[ -z "$(ls -A "${TOOLKIT_BACKUP_ROOT}" 2>/dev/null)" ]]; then
        echo_warn "No backups found in ${TOOLKIT_BACKUP_ROOT}"
        return 0
    fi

    echo_header "Available Backups"
    printf "%-20s %-16s %-12s %8s\n" "TIMESTAMP" "APP" "USER" "SIZE"
    printf "%-20s %-16s %-12s %8s\n" "─────────────────" "───────────────" "───────────" "───────"

    local total_size=0
    while IFS= read -r archive; do
        local session
        session=$(dirname "$archive" | xargs basename)
        local fname
        fname=$(basename "$archive")
        local name="${fname%.tar.gz}"
        # Parse app_user from filename (last _ separator)
        local app user
        app="${name%_*}"
        user="${name##*_}"

        [[ -n "$app_filter" ]] && [[ "$app" != "$app_filter" ]] && continue

        local size
        size=$(du -sh "$archive" 2>/dev/null | cut -f1)
        printf "%-20s %-16s %-12s %8s\n" "$session" "$app" "$user" "$size"
    done < <(find "${TOOLKIT_BACKUP_ROOT}" -name "*.tar.gz" -type f | sort)

    echo
    local total
    total=$(du -sh "${TOOLKIT_BACKUP_ROOT}" 2>/dev/null | cut -f1)
    printf "Total backup storage: %s\n" "$total"
    printf "Retention policy: keep last %d per app per user\n" "${BACKUP_RETENTION_COUNT}"
}

# ─── Restore ─────────────────────────────────────────────────────────────────

# Interactive restore or restore a specific archive
# Usage: run_restore [--file ARCHIVE] [--target APP] [--user USER]
run_restore() {
    local archive_path=""
    local app_filter=""
    local user_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)   archive_path="$2"; shift 2 ;;
            --target) app_filter="$2";   shift 2 ;;
            --user)   user_filter="$2";  shift 2 ;;
            *)        shift ;;
        esac
    done

    require_root

    # Load per-app backup modules
    for mod in rtorrent qbittorrent deluge transmission plex; do
        # shellcheck disable=SC1090
        source "${_BACKUP_MODULE_DIR}/${mod}.sh" 2>/dev/null || true
    done

    if [[ -z "$archive_path" ]]; then
        archive_path=$(_select_archive_interactive "$app_filter" "$user_filter")
        [[ -z "$archive_path" ]] && { echo_warn "No archive selected"; return 0; }
    fi

    if ! verify_archive "$archive_path"; then
        return 1
    fi

    # Determine app and user from filename
    local fname
    fname=$(basename "$archive_path" .tar.gz)
    local app="${fname%_*}"
    local user="${fname##*_}"
    [[ "$user" == "system" ]] && user=""

    echo_info "Restoring: ${app} for ${user:-system}"
    echo_info "Archive: ${archive_path}"

    confirm_action "This will OVERWRITE the current ${app} config. Continue?" || return 0

    # Dispatch to per-app restore
    case "$app" in
        rtorrent)     restore_rtorrent_user     "$user" "$archive_path" ;;
        qbittorrent)  restore_qbittorrent_user  "$user" "$archive_path" ;;
        deluge)       restore_deluge_user       "$user" "$archive_path" ;;
        transmission) restore_transmission_user "$user" "$archive_path" ;;
        plex)         restore_plex              "$archive_path"         ;;
        *)
            echo_error "Unknown app: ${app}. Restore aborted."
            return 1
            ;;
    esac
}

_select_archive_interactive() {
    local app_filter="${1:-}"
    local user_filter="${2:-}"

    if ! [[ -d "${TOOLKIT_BACKUP_ROOT}" ]]; then
        echo_warn "No backups found"
        return 1
    fi

    local -a archives
    mapfile -t archives < <(find "${TOOLKIT_BACKUP_ROOT}" -name "*.tar.gz" -type f | sort -r)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo_warn "No archives found"
        return 1
    fi

    # Filter if requested
    if [[ -n "$app_filter" ]] || [[ -n "$user_filter" ]]; then
        local -a filtered=()
        for a in "${archives[@]}"; do
            local fname; fname=$(basename "$a" .tar.gz)
            local app="${fname%_*}"
            local user="${fname##*_}"
            [[ -n "$app_filter"  ]] && [[ "$app"  != "$app_filter"  ]] && continue
            [[ -n "$user_filter" ]] && [[ "$user" != "$user_filter" ]] && continue
            filtered+=("$a")
        done
        archives=("${filtered[@]}")
    fi

    if command -v whiptail >/dev/null 2>&1; then
        local -a menu_items=()
        for i in "${!archives[@]}"; do
            local fname; fname=$(basename "${archives[$i]}" .tar.gz)
            local sz; sz=$(du -sh "${archives[$i]}" 2>/dev/null | cut -f1)
            menu_items+=("$i" "${fname} (${sz})")
        done
        local choice
        choice=$(whiptail --title "Select Backup to Restore" \
            --menu "Choose an archive:" 20 70 12 "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return 1
        echo "${archives[$choice]}"
    else
        echo_info "Available archives:"
        select archive in "${archives[@]}"; do
            [[ -n "$archive" ]] && { echo "$archive"; return 0; }
        done
    fi
}

# ─── Retention ───────────────────────────────────────────────────────────────

# Prune oldest archives keeping at most BACKUP_RETENTION_COUNT per app per user
enforce_retention() {
    local retention="${BACKUP_RETENTION_COUNT:-10}"
    [[ ! -d "${TOOLKIT_BACKUP_ROOT}" ]] && return 0

    # Get all unique app_user combinations
    local -a combos
    mapfile -t combos < <(
        find "${TOOLKIT_BACKUP_ROOT}" -name "*.tar.gz" -type f \
        | xargs -I{} basename {} .tar.gz \
        | sort -u
    )

    for combo in "${combos[@]}"; do
        # Find all archives for this app_user, oldest first
        local -a archives
        mapfile -t archives < <(
            find "${TOOLKIT_BACKUP_ROOT}" -name "${combo}.tar.gz" -type f \
            | sort  # lexicographic = chronological for YYYYMMDD_HHMMSS sessions
        )

        local count=${#archives[@]}
        if [[ $count -gt $retention ]]; then
            local to_delete=$(( count - retention ))
            echo_info "Pruning ${to_delete} old backup(s) of ${combo} (keeping ${retention})"
            for (( i=0; i<to_delete; i++ )); do
                dry_run_guard rm -f "${archives[$i]}"
            done
        fi
    done

    # Remove empty session directories
    find "${TOOLKIT_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -empty \
        -exec dry_run_guard rmdir {} \; 2>/dev/null || true
}
