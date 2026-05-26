#!/bin/bash
# =============================================================================
# notify.sh - desktop notification stub for the Linux tunnel monitor
# =============================================================================
# Usage: notify.sh <title> <message> [sound]
#
# IMPORTANT - this is intentionally a no-op stub.
#
# The macOS edition fires a Notification Center banner by injecting
# osascript into the console user's launchd session. There is no equivalent
# on Linux that is simple and reliable across:
#
#   * X11 vs Wayland
#   * Systemd-managed sessions (loginctl) vs raw startx
#   * Headless servers with no GUI user
#   * notify-send needing the right DBUS_SESSION_BUS_ADDRESS
#   * Daemon-context PolicyKit / TCC restrictions
#
# Rather than ship a fragile, easy-to-misconfigure injector, the Linux
# edition relies on:
#
#   1. Email alerts (always; see send-email.sh)
#   2. state.json (always; consumed by the tray app + tunnel-check CLI)
#   3. The tray app in Public/tray-app/ for desktop "glanceable" status
#
# This script logs each invocation so the operator can see what would have
# been shown, and always exits 0 so the caller never fails.
#
# Exit codes:
#   0  always (no-op success / call recorded)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/monitor.log"

show_help() {
    cat <<'EOF'
notify.sh - desktop notification stub (Linux edition)

USAGE
    notify.sh <title> <message> [sound]
    notify.sh --help

NOTES
    This script is intentionally a no-op. Linux daemon-context desktop
    notifications are unreliable across Wayland/X11/headless installs and
    are intentionally NOT attempted. Use email and the tray app for
    operator-visible alerts.

    Each call is logged to /opt/tunnel-monitor/monitor.log as
    "NOTIFY_SKIPPED title=... message=...".
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

TITLE="${1:-}"
MESSAGE="${2:-}"

ts="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] NOTIFY_SKIPPED title='${TITLE}' message='${MESSAGE}'"
printf '%s\n' "${ts}" >> "${LOG_FILE}" 2>/dev/null || true
printf '%s\n' "${ts}"

exit 0
