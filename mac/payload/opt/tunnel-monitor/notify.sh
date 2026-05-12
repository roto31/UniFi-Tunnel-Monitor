#!/bin/bash
# =============================================================================
# notify.sh — native macOS banner notification from a root LaunchDaemon
# =============================================================================
# Usage: notify.sh <title> <message> [sound]
#
# Apple notifications are tied to the user GUI session. A LaunchDaemon running
# as root cannot post a banner directly — it must inject the call into the
# console user's launchd context via:
#
#     launchctl asuser <uid> sudo -u <user> osascript -e 'display notification ...'
#
# `launchctl asuser` runs the command inside the per-user launchd context (so
# Notification Center, TCC, etc. resolve correctly) but the process itself is
# still root, so we drop privileges with `sudo -u` to satisfy AppleScript and
# the Notification Center sandbox.
#
# The whole call is wrapped in `timeout 5` to make sure the daemon never
# blocks on a hung osascript.
#
# Exit codes:
#   0  success or "no console user, skipped" (never fail loudly here)
#   1  bad invocation
# =============================================================================

set -euo pipefail

show_help() {
    cat <<'EOF'
notify.sh — native macOS banner notification from a root LaunchDaemon

USAGE
    notify.sh <title> <message> [sound]
    notify.sh --help

ARGUMENTS
    title     Short, declarative banner title (e.g. "Tunnel DOWN")
    message   One-sentence body with the actionable diagnosis
    sound     Optional sound name (default: Glass). Common: Glass, Hero, Ping.

NOTES
    Falls back to a no-op (exit 0) when no GUI user is logged in. First
    notification will be silently dropped until the operator grants
    Notification permission to "Script Editor"/osascript in System Settings.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

if [[ $# -lt 2 ]]; then
    echo "ERROR: expected at least 2 arguments (title, message)" >&2
    show_help >&2
    exit 1
fi

TITLE="$1"
MESSAGE="$2"
SOUND="${3:-Glass}"

# Escape embedded double-quotes and backslashes so the AppleScript literal stays valid.
escape_for_osa() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "${s}"
}

TITLE_ESC="$(escape_for_osa "${TITLE}")"
MESSAGE_ESC="$(escape_for_osa "${MESSAGE}")"
SOUND_ESC="$(escape_for_osa "${SOUND}")"

# Identify the console (GUI) user. /dev/console is owned by whoever is logged
# into the WindowServer session. If nobody is logged in, owner is "root" and
# there is no banner to display.
console_user="$(stat -f "%Su" /dev/console 2>/dev/null || true)"
console_uid="$(stat -f "%u" /dev/console 2>/dev/null || true)"

if [[ -z "${console_uid}" || -z "${console_user}" || "${console_user}" == "root" ]]; then
    echo "WARN: no GUI user logged in; skipping banner" >&2
    exit 0
fi

osa_script="display notification \"${MESSAGE_ESC}\" with title \"${TITLE_ESC}\" sound name \"${SOUND_ESC}\""

# If we are already running as the console user (e.g. invoked from tunnel-check
# in a Terminal), call osascript directly — sudo would prompt for a password.
current_uid="$(id -u)"

if [[ "${current_uid}" == "${console_uid}" ]]; then
    if ! timeout 5 osascript -e "${osa_script}" >/dev/null 2>&1; then
        echo "WARN: osascript failed (notifications likely not yet permitted)" >&2
    fi
    exit 0
fi

# Daemon path: inject into the console user's launchd context.
if ! timeout 5 launchctl asuser "${console_uid}" \
        sudo -u "${console_user}" \
        osascript -e "${osa_script}" >/dev/null 2>&1; then
    echo "WARN: launchctl asuser injection failed (banner not displayed)" >&2
fi

exit 0
