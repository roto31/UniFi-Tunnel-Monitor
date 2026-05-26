#!/bin/bash
# =============================================================================
# install.sh — Deploy wan-guard to hub gateway persistent storage
# Run as root on the hub gateway: bash install.sh
# =============================================================================

set -euo pipefail

INSTALL_DIR="/data/wan-guard"
SYSTEMD_DIR="/etc/systemd/system"
TUNNEL_MONITOR_CONFIG="/data/tunnel-monitor/config.env"

echo "=== wan-guard installer ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Create install directory
# ---------------------------------------------------------------------------
echo "[1/5] Creating ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# 2. Copy files
# ---------------------------------------------------------------------------
echo "[2/5] Installing scripts..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "${SCRIPT_DIR}/wan-guard.sh"    "${INSTALL_DIR}/wan-guard.sh"
chmod +x "${INSTALL_DIR}/wan-guard.sh"

# Symlink CLI command
ln -sf "${INSTALL_DIR}/wan-guard.sh" /usr/local/bin/wan-guard 2>/dev/null || \
    ln -sf "${INSTALL_DIR}/wan-guard.sh" /usr/bin/wan-guard

# ---------------------------------------------------------------------------
# 3. Config setup
# ---------------------------------------------------------------------------
echo "[3/5] Setting up config..."

if [[ -f "${TUNNEL_MONITOR_CONFIG}" ]]; then
    echo "  Found existing tunnel-monitor config at ${TUNNEL_MONITOR_CONFIG}"

    # Check if wan-guard keys already exist
    if grep -q "WAN_GUARD_INTERFACE" "${TUNNEL_MONITOR_CONFIG}" 2>/dev/null; then
        echo "  wan-guard config already present — skipping append"
    else
        echo "  Appending wan-guard config block..."
        echo "" >> "${TUNNEL_MONITOR_CONFIG}"
        cat "${SCRIPT_DIR}/config-additions.env" >> "${TUNNEL_MONITOR_CONFIG}"
        echo "  ✓ Appended to ${TUNNEL_MONITOR_CONFIG}"
        echo ""
        echo "  ⚠  ACTION REQUIRED: Edit ${TUNNEL_MONITOR_CONFIG}"
        echo "     Set WAN_GUARD_NOIP_PASS to your No-IP password"
    fi

    # Point wan-guard at the shared config
    ln -sf "${TUNNEL_MONITOR_CONFIG}" "${INSTALL_DIR}/config.env" 2>/dev/null || \
        cp "${TUNNEL_MONITOR_CONFIG}" "${INSTALL_DIR}/config.env"
else
    echo "  tunnel-monitor config not found — creating standalone config"
    cp "${SCRIPT_DIR}/config-additions.env" "${INSTALL_DIR}/config.env"
    echo ""
    echo "  ⚠  ACTION REQUIRED: Edit ${INSTALL_DIR}/config.env"
    echo "     Set WAN_GUARD_NOIP_PASS and SMTP credentials"
fi

# ---------------------------------------------------------------------------
# 4. Systemd units
# ---------------------------------------------------------------------------
echo "[4/5] Installing systemd units..."

cp "${SCRIPT_DIR}/wan-guard.service" "${SYSTEMD_DIR}/wan-guard.service"
cp "${SCRIPT_DIR}/wan-guard.timer"   "${SYSTEMD_DIR}/wan-guard.timer"

systemctl daemon-reload
systemctl enable wan-guard.timer
systemctl start  wan-guard.timer

echo "  ✓ Timer enabled and started"

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
echo "[5/5] Verification..."
echo ""
systemctl status wan-guard.timer --no-pager || true
echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit config: nano ${INSTALL_DIR}/config.env"
echo "     → Set WAN_GUARD_NOIP_PASS"
echo "  2. Test email:  wan-guard test-email"
echo "  3. Run check:   wan-guard check"
echo "  4. View status: wan-guard status"
echo "  5. Follow log:  wan-guard tail"
