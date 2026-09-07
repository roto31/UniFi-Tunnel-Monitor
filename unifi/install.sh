#!/bin/bash
# =============================================================================
# Tunnel Monitor Installer
# Run as root on the UniFi gateway:  bash install.sh
# Re-run after firmware updates to restore (since UniFi can wipe /etc/systemd/)
# =============================================================================

set -euo pipefail

TARGET_DIR="/data/tunnel-monitor"
SYSTEMD_DIR="/etc/systemd/system"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing tunnel monitor to ${TARGET_DIR}"
mkdir -p "$TARGET_DIR"

# Copy persistent files
install -m 0755 "${SOURCE_DIR}/monitor.sh"     "${TARGET_DIR}/monitor.sh"
install -m 0700 "${SOURCE_DIR}/send-email.sh"  "${TARGET_DIR}/send-email.sh"
install -m 0755 "${SOURCE_DIR}/tunnel-check"   "${TARGET_DIR}/tunnel-check"
install -m 0755 "${SOURCE_DIR}/heal.sh"        "${TARGET_DIR}/heal.sh"

# Preserve existing config if present; otherwise drop template
if [[ ! -f "${TARGET_DIR}/config.env" ]]; then
    install -m 0600 "${SOURCE_DIR}/config.env.template" "${TARGET_DIR}/config.env"
    echo "==> Config template installed to ${TARGET_DIR}/config.env"
    echo "    EDIT THIS FILE NOW and fill in SMTP_PASSWORD before continuing."
else
    echo "==> Existing config.env preserved at ${TARGET_DIR}/config.env"
fi

# Initialize state if missing
[[ -f "${TARGET_DIR}/state" ]] || echo "0:UP" > "${TARGET_DIR}/state"
chmod 0644 "${TARGET_DIR}/state"

# Heal counters/log survive firmware; never clobber on re-run
if [[ ! -f "${TARGET_DIR}/heal-state" ]]; then
    cat > "${TARGET_DIR}/heal-state" <<'EOF'
attempts_today=0
attempts_day=
consecutive_fails=0
last_cycle_epoch=0
last_result=
cooldown_until_epoch=0
exhausted_alerted=0
capped_alerted=0
EOF
    echo "==> Initialized ${TARGET_DIR}/heal-state"
else
    echo "==> Existing heal-state preserved at ${TARGET_DIR}/heal-state"
fi
[[ -f "${TARGET_DIR}/heal.log" ]] || touch "${TARGET_DIR}/heal.log"
chmod 0644 "${TARGET_DIR}/heal-state" "${TARGET_DIR}/heal.log"


# Install systemd units
install -m 0644 "${SOURCE_DIR}/tunnel-monitor.service" "${SYSTEMD_DIR}/tunnel-monitor.service"
install -m 0644 "${SOURCE_DIR}/tunnel-monitor.timer"   "${SYSTEMD_DIR}/tunnel-monitor.timer"

# Symlink the diagnostic CLI into /usr/local/bin so you can just type `tunnel-check`
ln -sf "${TARGET_DIR}/tunnel-check" /usr/local/bin/tunnel-check

# Reload systemd and enable timer
systemctl daemon-reload
systemctl enable --now tunnel-monitor.timer

echo
echo "==> Installation complete."
echo
echo "Next steps:"
echo "  1. Edit ${TARGET_DIR}/config.env and replace every REPLACE_WITH_*"
echo "     value (especially SMTP_PASSWORD — generate an app-specific"
echo "     password with your SMTP provider; do NOT use your account password)."
echo
echo "  2. Test the email pipeline:"
echo "       tunnel-check --test-email"
echo
echo "  3. Watch the live monitor logs:"
echo "       tunnel-check --tail"
echo
echo "  4. Trigger a one-shot check immediately:"
echo "       systemctl start tunnel-monitor.service"
echo "       journalctl -u tunnel-monitor.service --no-pager -n 30"
echo
echo "  5. See timer status:"
echo "       systemctl list-timers tunnel-monitor.timer"
echo
echo "  6. From this source directory: bash verify.sh"

