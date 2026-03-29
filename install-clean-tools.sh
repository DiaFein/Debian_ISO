#!/bin/bash
# Smart Installer for clean-base and clean-live (SAFE VERSION)
# Usage: sudo ./install-clean-tools.sh [install|uninstall]

set -euo pipefail

TOOLS_DIR="/usr/local/bin"
LOG_FILE="/var/log/clean-tools.log"

install_tools() {
    echo "[*] Installing SMART cleanup tools into $TOOLS_DIR..."

    # -------------------------
    # CLEAN-BASE (SAFE VERSION)
    # -------------------------
    cat > "$TOOLS_DIR/clean-base" <<'EOF'
#!/bin/bash
set -euo pipefail

echo "[*] Smart cleaning Debian base system..."

# APT cleanup
apt-get clean
apt-get autoclean
apt-get autoremove -y

# Journal cleanup (keep last 7 days OR max 200MB)
journalctl --vacuum-time=7d
journalctl --vacuum-size=200M

# Logs: keep structure, don't delete files
find /var/log -type f -name "*.log" -mtime +7 -exec truncate -s 0 {} \;

# Temp cleanup
systemd-tmpfiles --clean
rm -rf /tmp/* /var/tmp/*

# Thumbnail cache only (safe)
rm -rf /home/*/.cache/thumbnails/*

# Crash dumps
rm -rf /var/crash/*

echo "[+] Base system smart cleanup complete."
EOF


    # -------------------------
    # CLEAN-LIVE (TORAM SAFE)
    # -------------------------
    cat > "$TOOLS_DIR/clean-live" <<'EOF'
#!/bin/bash
set -euo pipefail

echo "[*] Smart cleaning LIVE (toram + persistence)..."

# Check persistence usage
PERSIST=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

echo "[*] Persistence usage: ${PERSIST}%"

# Only clean aggressively if >70%
if [ "$PERSIST" -gt 70 ]; then
    echo "[!] High usage detected → aggressive cleanup"

    apt-get clean
    apt-get autoclean

    # Logs (truncate only)
    find /var/log -type f -exec truncate -s 0 {} \;

    # Temp
    rm -rf /tmp/* /var/tmp/*

    # Browser SAFE cache trim (not delete)
    find /home -type d -path "*/cache2/*" -type f -delete 2>/dev/null || true

    # General cache (limit instead of delete)
    find /home -type d -path "*/.cache/*" -type f -size +50M -delete

else
    echo "[*] Usage normal → light cleanup"

    # Light cleanup only
    apt-get clean
    rm -rf /tmp/*

    # Trim only large cache files
    find /home -type f -path "*/.cache/*" -size +100M -delete
fi

systemd-tmpfiles --clean

echo "[+] Live system smart cleanup complete."
EOF

    chmod +x "$TOOLS_DIR/clean-base" "$TOOLS_DIR/clean-live"

    echo "[+] SMART tools installed successfully."
}

uninstall_tools() {
    echo "[*] Removing cleanup tools..."
    rm -f "$TOOLS_DIR/clean-base" "$TOOLS_DIR/clean-live"
    echo "[+] Tools removed."
}

case "${1:-install}" in
    install) install_tools ;;
    uninstall) uninstall_tools ;;
    *) echo "Usage: $0 [install|uninstall]" ; exit 1 ;;
esac
