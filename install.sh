#!/usr/bin/env bash
# install.sh — Install swizzin-toolkit to the system
#
# What this does:
#   1. Copies the toolkit to INSTALL_DIR (/opt/swizzin-toolkit)
#   2. Makes all .sh files executable
#   3. Creates a symlink: /usr/local/bin/toolkit → INSTALL_DIR/toolkit.sh
#   4. Creates backup directory /root/swizzin-toolkit-backups/
#   5. Creates config directory /etc/swizzin-toolkit/ with defaults.conf
#   6. If swizzin is installed: optionally integrates with box command
#   7. Sets up log file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${TOOLKIT_INSTALL_DIR:-/opt/swizzin-toolkit}"
BIN_LINK="/usr/local/bin/toolkit"
CONFIG_DIR="/etc/swizzin-toolkit"
BACKUP_ROOT="${TOOLKIT_BACKUP_ROOT:-/root/swizzin-toolkit-backups}"
LOG_FILE="${TOOLKIT_LOG:-/var/log/swizzin-toolkit.log}"

# ─── Root check ──────────────────────────────────────────────────────────────

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: install.sh must be run as root."
    exit 1
fi

echo "======================================================"
echo "  swizzin-toolkit installer"
echo "======================================================"
echo

# ─── Step 1: Copy files ──────────────────────────────────────────────────────

echo "→ Installing to ${INSTALL_DIR}..."

_resolve() { realpath "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1"; }
SCRIPT_DIR_REAL="$(_resolve "$SCRIPT_DIR")"
INSTALL_DIR_REAL="$(_resolve "$INSTALL_DIR")"

if [[ "$SCRIPT_DIR_REAL" == "$INSTALL_DIR_REAL" ]]; then
    echo "  Already running from ${INSTALL_DIR} — skipping copy."
else
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "  Updating existing installation..."
        cp -r "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    mkdir -p "$INSTALL_DIR"
    cp -r "${SCRIPT_DIR}/." "${INSTALL_DIR}/"
fi

# ─── Step 2: Fix permissions ─────────────────────────────────────────────────

echo "→ Setting file permissions..."
find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \;
chmod +x "${INSTALL_DIR}/toolkit.sh"

# ─── Step 3: Symlink ─────────────────────────────────────────────────────────

echo "→ Creating symlink: ${BIN_LINK}..."
ln -sf "${INSTALL_DIR}/toolkit.sh" "$BIN_LINK"
chmod +x "$BIN_LINK"

# ─── Step 4: Backup directory ────────────────────────────────────────────────

echo "→ Creating backup directory: ${BACKUP_ROOT}..."
mkdir -p "${BACKUP_ROOT}/.tuning"
chmod 700 "$BACKUP_ROOT"

# ─── Step 5: Config directory ────────────────────────────────────────────────

echo "→ Creating config directory: ${CONFIG_DIR}..."
mkdir -p "$CONFIG_DIR"

# Write resolved defaults.conf (with actual paths substituted)
cat > "${CONFIG_DIR}/defaults.conf" <<CONF
# swizzin-toolkit configuration
# Installed: $(date)
# Edit this file to override defaults.

TOOLKIT_BACKUP_ROOT="${BACKUP_ROOT}"
TOOLKIT_TUNE_BACKUP_ROOT="${BACKUP_ROOT}/.tuning"
TOOLKIT_INSTALL_DIR="${INSTALL_DIR}"
TOOLKIT_SYSCTL_FILE="/etc/sysctl.d/99-swizzin-toolkit.conf"
TOOLKIT_UDEV_RULE="/etc/udev/rules.d/60-swizzin-toolkit-scheduler.rules"
TOOLKIT_PLEX_OVERRIDE_DIR="/etc/systemd/system/plexmediaserver.service.d"
TOOLKIT_PLEX_OVERRIDE_FILE="swizzin-toolkit.conf"
TOOLKIT_LOG="${LOG_FILE}"
BACKUP_RETENTION_COUNT=10
PLEX_DATA_PATH="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
SWIZZIN_LOCK_DIR="/install"
SWIZZIN_MASTER_INFO="/root/.master.info"
SWIZZIN_GLOBALS="/etc/swizzin/sources/globals.sh"
CONF

# Make toolkit.sh load the system config if it exists
# (It already loads conf/defaults.conf from TOOLKIT_ROOT, but system config takes precedence)
if ! grep -q "system config" "${INSTALL_DIR}/toolkit.sh" 2>/dev/null; then
    # Insert system config loading before defaults
    sed -i '/source "\${TOOLKIT_ROOT}\/conf\/defaults.conf"/i # Load system config if present\n[[ -f "'"${CONFIG_DIR}/defaults.conf"'" ]] \&\& source "'"${CONFIG_DIR}/defaults.conf"'"\n' \
        "${INSTALL_DIR}/toolkit.sh" 2>/dev/null || true
fi

# ─── Step 6: Log file ────────────────────────────────────────────────────────

echo "→ Setting up log file: ${LOG_FILE}..."
touch "$LOG_FILE" 2>/dev/null || true
chmod 640 "$LOG_FILE" 2>/dev/null || true

# ─── Step 7: Swizzin integration (optional) ──────────────────────────────────

SWIZZIN_SCRIPTS="/etc/swizzin/scripts"
if [[ -d "$SWIZZIN_SCRIPTS" ]]; then
    echo
    echo "→ Swizzin installation detected!"
    echo "  Swizzin integration options:"
    echo "  [1] Replace swizzin's tune script with toolkit version"
    echo "  [2] Replace swizzin's backup script with toolkit version"
    echo "  [3] Both"
    echo "  [4] Skip integration (toolkit runs independently)"
    echo
    printf "Choose [1/2/3/4]: "
    read -r choice

    case "${choice:-4}" in
        1|3)
            echo "  → Backing up original tune script..."
            [[ -f "${SWIZZIN_SCRIPTS}/tune" ]] && \
                cp "${SWIZZIN_SCRIPTS}/tune" "${SWIZZIN_SCRIPTS}/tune.bak.$(date +%Y%m%d_%H%M%S)"
            echo "  → Installing toolkit tune wrapper..."
            cat > "${SWIZZIN_SCRIPTS}/tune" <<'TUNE_WRAPPER'
#!/usr/bin/env bash
# swizzin tune — redirects to swizzin-toolkit
exec /usr/local/bin/toolkit tune "$@"
TUNE_WRAPPER
            chmod +x "${SWIZZIN_SCRIPTS}/tune"
            echo "  ✓ tune script replaced"
            ;;&
        2|3)
            echo "  → Backing up original backup script..."
            [[ -f "${SWIZZIN_SCRIPTS}/backup" ]] && \
                cp "${SWIZZIN_SCRIPTS}/backup" "${SWIZZIN_SCRIPTS}/backup.bak.$(date +%Y%m%d_%H%M%S)"
            echo "  → Installing toolkit backup wrapper..."
            cat > "${SWIZZIN_SCRIPTS}/backup" <<'BACKUP_WRAPPER'
#!/usr/bin/env bash
# swizzin backup — redirects to swizzin-toolkit
exec /usr/local/bin/toolkit backup "$@"
BACKUP_WRAPPER
            chmod +x "${SWIZZIN_SCRIPTS}/backup"
            echo "  ✓ backup script replaced"
            ;;
        4|*)
            echo "  Skipping swizzin integration."
            ;;
    esac
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo
echo "======================================================"
echo "  Installation complete!"
echo "======================================================"
echo
echo "  Usage:  toolkit [subcommand] [options]"
echo "  Help:   toolkit help"
echo "  Status: toolkit status"
echo "  Tune:   toolkit tune --dry-run --target all"
echo "  Backup: toolkit backup --target all"
echo
echo "  Config: ${CONFIG_DIR}/defaults.conf"
echo "  Backups: ${BACKUP_ROOT}/"
echo "  Log: ${LOG_FILE}"
echo
