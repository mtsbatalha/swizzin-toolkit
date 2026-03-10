#!/usr/bin/env bash
# uninstall.sh — Remove swizzin-toolkit from the system
#
# Removes:
#   - Installation directory (/opt/swizzin-toolkit)
#   - Symlink (/usr/local/bin/toolkit)
#   - Config directory (/etc/swizzin-toolkit)
#   - sysctl config file
#   - udev rule
#   - Plex systemd override (if present)
#   - Log file (optional)
#
# Does NOT remove:
#   - Backup archives in BACKUP_ROOT (your data is safe)
#   - swizzin's original scripts (backups were made during install)

set -euo pipefail

INSTALL_DIR="${TOOLKIT_INSTALL_DIR:-/opt/swizzin-toolkit}"
BIN_LINK="/usr/local/bin/toolkit"
CONFIG_DIR="/etc/swizzin-toolkit"
SYSCTL_FILE="/etc/sysctl.d/99-swizzin-toolkit.conf"
UDEV_RULE="/etc/udev/rules.d/60-swizzin-toolkit-scheduler.rules"
PLEX_OVERRIDE_DIR="/etc/systemd/system/plexmediaserver.service.d"
PLEX_OVERRIDE_FILE="${PLEX_OVERRIDE_DIR}/swizzin-toolkit.conf"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: uninstall.sh must be run as root."
    exit 1
fi

echo "======================================================"
echo "  swizzin-toolkit uninstaller"
echo "======================================================"
echo

printf "This will remove swizzin-toolkit from your system.\nYour backup archives will NOT be deleted.\nContinue? [y/N]: "
read -r confirm
[[ "$confirm" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }

# Remove symlink
[[ -L "$BIN_LINK" ]] && { echo "→ Removing symlink ${BIN_LINK}..."; rm -f "$BIN_LINK"; }

# Remove installation directory
[[ -d "$INSTALL_DIR" ]] && { echo "→ Removing ${INSTALL_DIR}..."; rm -rf "$INSTALL_DIR"; }

# Remove config directory
[[ -d "$CONFIG_DIR" ]] && { echo "→ Removing ${CONFIG_DIR}..."; rm -rf "$CONFIG_DIR"; }

# Remove sysctl config and restore defaults
if [[ -f "$SYSCTL_FILE" ]]; then
    echo "→ Removing sysctl config ${SYSCTL_FILE}..."
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
fi

# Remove udev rule
if [[ -f "$UDEV_RULE" ]]; then
    echo "→ Removing udev rule ${UDEV_RULE}..."
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules 2>/dev/null || true
fi

# Remove Plex systemd override
if [[ -f "$PLEX_OVERRIDE_FILE" ]]; then
    echo "→ Removing Plex systemd override ${PLEX_OVERRIDE_FILE}..."
    rm -f "$PLEX_OVERRIDE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    # Try to restart Plex to pick up removal of override
    systemctl restart plexmediaserver 2>/dev/null || true
fi

# Remove empty Plex override dir if we created it
[[ -d "$PLEX_OVERRIDE_DIR" ]] && rmdir --ignore-fail-on-non-empty "$PLEX_OVERRIDE_DIR" 2>/dev/null || true

# Restore swizzin scripts if backups exist
SWIZZIN_SCRIPTS="/etc/swizzin/scripts"
if [[ -d "$SWIZZIN_SCRIPTS" ]]; then
    for script in tune backup; do
        local_bak=$(ls -1t "${SWIZZIN_SCRIPTS}/${script}.bak."* 2>/dev/null | head -1)
        if [[ -n "$local_bak" ]]; then
            echo "→ Restoring swizzin ${script} script from ${local_bak}..."
            cp "$local_bak" "${SWIZZIN_SCRIPTS}/${script}"
            chmod +x "${SWIZZIN_SCRIPTS}/${script}"
        fi
    done
fi

# Optional: remove log file
printf "\nRemove log file /var/log/swizzin-toolkit.log? [y/N]: "
read -r rm_log
if [[ "$rm_log" =~ ^[yY] ]]; then
    rm -f /var/log/swizzin-toolkit.log
    echo "→ Log file removed."
fi

echo
echo "======================================================"
echo "  Uninstall complete."
echo
echo "  Your backup archives are still in:"
echo "  ${TOOLKIT_BACKUP_ROOT:-/root/swizzin-toolkit-backups}"
echo "======================================================"
