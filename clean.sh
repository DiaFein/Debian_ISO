#!/bin/bash
# Installer for clean-base and clean-live tools
# Usage: sudo ./install-clean-tools.sh [install|uninstall]
#sudo ./install-clean-tools.sh install
#sudo ./install-clean-tools.sh uninstall
#sudo clean-base
#sudo clean-live


set -euo pipefail

TOOLS_DIR="/usr/local/bin"

install_tools() {
    echo "[*] Installing cleanup tools into $TOOLS_DIR..."

    # Create clean-base
    cat > "$TOOLS_DIR/clean-base" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "[*] Cleaning Debian base system..."
apt-get clean
apt-get autoclean
apt-get autoremove -y
journalctl --vacuum-time=7d
rm -rf /home/*/.cache/thumbnails/*
systemd-tmpfiles --clean
rm -rf /tmp/* /var/tmp/*
rm -rf /var/crash/*
find /var/log -type f -name "*.log" -mtime +7 -exec truncate -s 0 {} \;
echo "[+] Base system cleanup complete."
EOF

    # Create clean-live
    cat > "$TOOLS_DIR/clean-live" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "[*] Cleaning toram live system..."
apt-get clean
apt-get autoclean
rm -rf /tmp/* /var/tmp/*
rm -rf /var/log/*
systemd-tmpfiles --clean
rm -rf /home/*/.cache/*
rm -rf /home/*/.mozilla/firefox/*.default-release/cache2/*
echo "[+] Live system cleanup complete."
EOF

    # Make them executable
    chmod +x "$TOOLS_DIR/clean-base" "$TOOLS_DIR/clean-live"

    echo "[+] Tools installed successfully."
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
