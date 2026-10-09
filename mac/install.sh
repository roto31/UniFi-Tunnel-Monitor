#!/bin/bash
# =============================================================================
# install.sh — bulletproof, idempotent installer for the Mac tunnel monitor
# =============================================================================
# Run from the workspace root:
#     sudo bash install.sh
# Re-running is safe and never destroys config.env or state.json.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${REPO_DIR}/payload"
SRC_OPT="${PAYLOAD_DIR}/opt/tunnel-monitor"
SRC_PLIST="${PAYLOAD_DIR}/LaunchDaemons/com.example.tunnel-monitor.plist"
SRC_SWIFTBAR="${PAYLOAD_DIR}/SwiftBar/tunnel-monitor.30s.sh"

INSTALL_DIR="/opt/tunnel-monitor"
SSH_DIR="${INSTALL_DIR}/.ssh"
SSH_KEY="${SSH_DIR}/id_ed25519"
SSH_PUB="${SSH_KEY}.pub"
LAUNCHD_LABEL="com.example.tunnel-monitor"
PLIST_DEST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
SYMLINK_DEST="/usr/local/bin/tunnel-check"

ROUTER_HOST_DEFAULT="REPLACE_WITH_ROUTER_LAN_IP"
ROUTER_USER_DEFAULT="root"

# -----------------------------------------------------------------------------
# Pretty printing
# -----------------------------------------------------------------------------

bold()  { printf '\033[1m%s\033[0m\n'    "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
install.sh — installer for the Mac tunnel monitor

USAGE
    sudo bash install.sh
    bash install.sh --help

WHAT IT DOES
    1. Preflight (macOS, root, deps, SwiftBar)
    2. Lay down /opt/tunnel-monitor/ files with correct perms
    3. Generate + authorize SSH key on the router (if missing)
    4. Install + load /Library/LaunchDaemons/com.example.tunnel-monitor.plist
    5. Drop the SwiftBar plugin in the user's plugins folder
    6. Print post-install steps

Re-runs are safe: config.env and state.json are preserved.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

# -----------------------------------------------------------------------------
# Phase 1 — Preflight
# -----------------------------------------------------------------------------

step "Phase 1 — Preflight"

if [[ "$(uname)" != "Darwin" ]]; then
    red "ERROR: this installer only runs on macOS (Darwin)."
    exit 3
fi

if [[ ${EUID} -ne 0 ]]; then
    yellow "Re-executing under sudo..."
    exec sudo --preserve-env=SUDO_USER bash "${BASH_SOURCE[0]}" "$@"
fi

# Identify the invoking (non-root) user — needed for Homebrew + SwiftBar paths.
INVOKER_USER="${SUDO_USER:-}"
if [[ -z "${INVOKER_USER}" || "${INVOKER_USER}" == "root" ]]; then
    INVOKER_USER="$(stat -f "%Su" /dev/console 2>/dev/null || echo "")"
fi
if [[ -z "${INVOKER_USER}" || "${INVOKER_USER}" == "root" ]]; then
    red "ERROR: cannot determine the non-root invoking user (need it for Homebrew + SwiftBar paths)."
    red "       Run from a Terminal logged in as your normal user with sudo."
    exit 2
fi
INVOKER_HOME="$(eval echo "~${INVOKER_USER}")"
INVOKER_UID="$(id -u "${INVOKER_USER}")"
green "Invoking user: ${INVOKER_USER} (uid=${INVOKER_UID}, home=${INVOKER_HOME})"

# Verify payload exists.
for required in \
    "${SRC_OPT}/monitor.sh" \
    "${SRC_OPT}/send-email.sh" \
    "${SRC_OPT}/notify.sh" \
    "${SRC_OPT}/tunnel-check" \
    "${SRC_OPT}/ssh-router-state.sh" \
    "${SRC_OPT}/ssh-spoke-state.sh" \
    "${SRC_OPT}/config.env.template" \
    "${SRC_PLIST}" \
    "${SRC_SWIFTBAR}"
do
    if [[ ! -f "${required}" ]]; then
        red "ERROR: missing payload file: ${required}"
        exit 1
    fi
done
green "Payload looks complete."

# Verify required binaries / install jq via Homebrew if missing.
require_or_install_jq() {
    if command -v jq >/dev/null 2>&1; then
        green "jq already installed: $(command -v jq)"
        return 0
    fi
    if ! command -v brew >/dev/null 2>&1 && \
       [[ ! -x /opt/homebrew/bin/brew ]] && \
       [[ ! -x /usr/local/bin/brew ]]; then
        red "ERROR: Homebrew is required to install jq automatically."
        red "       Install Homebrew first: https://brew.sh"
        exit 3
    fi
    yellow "Installing jq via Homebrew (as ${INVOKER_USER})..."
    if ! sudo -u "${INVOKER_USER}" -i bash -lc 'brew install jq'; then
        red "ERROR: brew install jq failed"
        exit 3
    fi
    green "jq installed."
}

require_or_install_jq

for c in curl dig ssh ssh-keygen osascript launchctl; do
    if ! command -v "$c" >/dev/null 2>&1; then
        red "ERROR: missing required command: $c"
        exit 3
    fi
done
green "All required commands present."

# SwiftBar check (warn-only — operator can install later, plugin still drops in place).
SWIFTBAR_INSTALLED=false
if [[ -d "/Applications/SwiftBar.app" ]]; then
    SWIFTBAR_INSTALLED=true
    green "SwiftBar is installed."
else
    yellow "SwiftBar.app not found in /Applications. Install it with:"
    yellow "    brew install --cask swiftbar"
    yellow "Continuing — the plugin will still be deployed to its plugins directory."
fi

# -----------------------------------------------------------------------------
# Phase 2 — File installation
# -----------------------------------------------------------------------------

step "Phase 2 — File installation"

mkdir -p "${INSTALL_DIR}"
chown root:wheel "${INSTALL_DIR}"
chmod 0755 "${INSTALL_DIR}"

install_file() {
    local src="$1" dest="$2" mode="$3"
    install -m "${mode}" -o root -g wheel "${src}" "${dest}"
    green "Installed ${dest} (mode ${mode})"
}

install_file "${SRC_OPT}/monitor.sh"         "${INSTALL_DIR}/monitor.sh"         0755
install_file "${SRC_OPT}/notify.sh"          "${INSTALL_DIR}/notify.sh"          0755
install_file "${SRC_OPT}/tunnel-check"       "${INSTALL_DIR}/tunnel-check"       0755
install_file "${SRC_OPT}/send-email.sh"      "${INSTALL_DIR}/send-email.sh"      0750
install_file "${SRC_OPT}/ssh-router-state.sh"  "${INSTALL_DIR}/ssh-router-state.sh"  0750
install_file "${SRC_OPT}/ssh-spoke-state.sh"   "${INSTALL_DIR}/ssh-spoke-state.sh"   0750

# Always install the template at 0644 (no secrets in it).
install_file "${SRC_OPT}/config.env.template" "${INSTALL_DIR}/config.env.template" 0644

# Preserve existing config.env on re-runs.
if [[ -f "${INSTALL_DIR}/config.env" ]]; then
    yellow "config.env already exists — leaving it untouched."
    chmod 0600 "${INSTALL_DIR}/config.env"
    chown root:wheel "${INSTALL_DIR}/config.env"
else
    install -m 0600 -o root -g wheel "${SRC_OPT}/config.env.template" "${INSTALL_DIR}/config.env"
    yellow "Wrote starter config.env from template."
    yellow "    Edit it and set SMTP_PASSWORD before testing email."
fi

# Initialize state.json if missing.
if [[ ! -f "${INSTALL_DIR}/state.json" ]]; then
    NOW="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    cat > "${INSTALL_DIR}/state.json.tmp" <<JSON
{
  "timestamp": "${NOW}",
  "alert_state": "UP",
  "failure_count": 0,
  "checks": {
    "tunnel":       { "target": null, "ok": null, "latency_ms": null },
    "remote_wan":   { "target": null, "ok": null, "latency_ms": null },
    "our_internet": { "target": null, "ok": null, "latency_ms": null },
    "dns":          { "host": null, "resolved": null, "expected": null, "match": null }
  },
  "router_dedup":   { "reachable": false, "state": null, "checked_at": "${NOW}" },
  "last_alert_sent_at":    null,
  "last_recovery_sent_at": null,
  "diagnosis": "PENDING_FIRST_RUN"
}
JSON
    mv "${INSTALL_DIR}/state.json.tmp" "${INSTALL_DIR}/state.json"
    chmod 0644 "${INSTALL_DIR}/state.json"
    chown root:wheel "${INSTALL_DIR}/state.json"
    green "Initialized state.json with PENDING_FIRST_RUN."
else
    yellow "state.json already present — leaving it untouched."
fi

# Initialize empty log file with proper perms (so first daemon run can append).
touch "${INSTALL_DIR}/monitor.log"
chmod 0644 "${INSTALL_DIR}/monitor.log"
chown root:wheel "${INSTALL_DIR}/monitor.log"

# Symlink the CLI.
if [[ -L "${SYMLINK_DEST}" || -e "${SYMLINK_DEST}" ]]; then
    rm -f "${SYMLINK_DEST}"
fi
mkdir -p "$(dirname "${SYMLINK_DEST}")"
ln -s "${INSTALL_DIR}/tunnel-check" "${SYMLINK_DEST}"
green "Symlinked ${SYMLINK_DEST} -> ${INSTALL_DIR}/tunnel-check"

# -----------------------------------------------------------------------------
# Phase 3 — SSH key for router-side dedup
# -----------------------------------------------------------------------------

step "Phase 3 — SSH key for router-side dedup"

mkdir -p "${SSH_DIR}"
chown root:wheel "${SSH_DIR}"
chmod 0700 "${SSH_DIR}"

if [[ -f "${SSH_KEY}" ]]; then
    green "SSH key already exists at ${SSH_KEY} — keeping it."
else
    yellow "Generating new ed25519 key for router-side dedup SSH..."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "tunnel-monitor@mac" >/dev/null
    green "Generated ${SSH_KEY}"
fi
chown root:wheel "${SSH_KEY}" "${SSH_PUB}"
chmod 0600 "${SSH_KEY}"
chmod 0644 "${SSH_PUB}"

# Determine router host from config.env if present, else default.
ROUTER_HOST="${ROUTER_HOST_DEFAULT}"
ROUTER_USER="${ROUTER_USER_DEFAULT}"
if [[ -f "${INSTALL_DIR}/config.env" ]]; then
    # shellcheck disable=SC1090
    source "${INSTALL_DIR}/config.env" >/dev/null 2>&1 || true
    ROUTER_HOST="${ROUTER_HOST:-${ROUTER_HOST_DEFAULT}}"
    ROUTER_USER="${ROUTER_USER:-${ROUTER_USER_DEFAULT}}"
fi

# If config.env still has the template placeholder, skip the SSH key push
# step — there's no point attempting a connection to a literal placeholder.
if [[ "${ROUTER_HOST}" == "REPLACE_WITH_ROUTER_LAN_IP" ]]; then
    yellow ""
    yellow "==> Skipping router SSH key authorization."
    yellow "    config.env still has placeholder ROUTER_HOST=REPLACE_WITH_ROUTER_LAN_IP."
    yellow "    After you edit /opt/tunnel-monitor/config.env with your router's"
    yellow "    real LAN IP and SSH username, re-run this installer to push the key."
    yellow ""
    SKIP_ROUTER_AUTH=1
else
    SKIP_ROUTER_AUTH=0
fi

test_router_key() {
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${SSH_DIR}/known_hosts" \
        -i "${SSH_KEY}" \
        "${ROUTER_USER}@${ROUTER_HOST}" 'echo OK' 2>/dev/null | grep -q '^OK$'
}

if [[ "${SKIP_ROUTER_AUTH}" == "1" ]]; then
    yellow "Continuing without authorizing the router SSH key."
elif test_router_key; then
    green "SSH key already authorized on ${ROUTER_USER}@${ROUTER_HOST}."
else
    yellow ""
    yellow "==> SSH key needs to be authorized on the router."
    yellow "    You will be prompted for the router root password ONCE."
    yellow ""
    if ! cat "${SSH_PUB}" | ssh \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${SSH_DIR}/known_hosts" \
            "${ROUTER_USER}@${ROUTER_HOST}" \
            'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'
    then
        red "ERROR: failed to push pubkey to ${ROUTER_USER}@${ROUTER_HOST}."
        red "       You can do it manually with:"
        red "         ssh-copy-id -i ${SSH_PUB} ${ROUTER_USER}@${ROUTER_HOST}"
        red "       Then re-run this installer."
        exit 1
    fi
    if test_router_key; then
        green "SSH key successfully authorized."
    else
        red "ERROR: pubkey was sent but key still does not authenticate."
        red "       Check ${ROUTER_USER}@${ROUTER_HOST}:~/.ssh/authorized_keys manually."
        exit 1
    fi
fi

chmod 0600 "${SSH_DIR}/known_hosts" 2>/dev/null || true
chown root:wheel "${SSH_DIR}/known_hosts" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Phase 4 — LaunchDaemon registration
# -----------------------------------------------------------------------------

step "Phase 4 — LaunchDaemon registration"

install -m 0644 -o root -g wheel "${SRC_PLIST}" "${PLIST_DEST}"
green "Installed ${PLIST_DEST}"

# Bootout (unload) safely first; tolerate "not loaded".
if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    yellow "Daemon already loaded — bootout first..."
    launchctl bootout system "${PLIST_DEST}" 2>/dev/null || true
fi

if ! launchctl bootstrap system "${PLIST_DEST}"; then
    red "ERROR: launchctl bootstrap failed."
    red "       Try: sudo launchctl bootstrap system ${PLIST_DEST}"
    exit 1
fi
launchctl enable "system/${LAUNCHD_LABEL}" || true
green "Daemon loaded and enabled (label: ${LAUNCHD_LABEL})."

# -----------------------------------------------------------------------------
# Phase 5 — SwiftBar plugin install
# -----------------------------------------------------------------------------

step "Phase 5 — SwiftBar plugin"

# Try to read SwiftBar's configured plugin directory from the invoker's defaults.
PLUGIN_DIR=""
if PD="$(sudo -u "${INVOKER_USER}" defaults read com.ainvyu.SwiftBar PluginDirectory 2>/dev/null)"; then
    PLUGIN_DIR="${PD}"
fi
if [[ -z "${PLUGIN_DIR}" ]]; then
    PLUGIN_DIR="${INVOKER_HOME}/Library/Application Support/SwiftBar/Plugins"
fi

# Expand a leading ~ in case defaults returned one.
PLUGIN_DIR="${PLUGIN_DIR/#\~/${INVOKER_HOME}}"

mkdir -p "${PLUGIN_DIR}"
chown -R "${INVOKER_USER}":staff "${PLUGIN_DIR}"

PLUGIN_DEST="${PLUGIN_DIR}/tunnel-monitor.30s.sh"
install -m 0755 -o "${INVOKER_USER}" -g staff "${SRC_SWIFTBAR}" "${PLUGIN_DEST}"
green "Installed ${PLUGIN_DEST}"

# Touch to nudge SwiftBar to reload.
sudo -u "${INVOKER_USER}" touch "${PLUGIN_DEST}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Phase 6 — Post-install
# -----------------------------------------------------------------------------

step "Phase 6 — Post-install steps"

bold "Next steps for the operator:"
cat <<EOF

  1. Set the SMTP password (and verify other config):
       sudo vi /opt/tunnel-monitor/config.env

  2. Test the email path:
       tunnel-check --test-email

  3. Test the banner notification path:
       tunnel-check --test-notify
     (First time: macOS will show a permission prompt for "Script Editor"
      or osascript. Approve it. The first banner may be silently dropped.)

  4. See live status:
       tunnel-check

  5. Force an immediate health check:
       sudo tunnel-check --check-now

  6. Verify the install is healthy:
       sudo bash ${REPO_DIR}/verify.sh

EOF

if [[ "${SWIFTBAR_INSTALLED}" != "true" ]]; then
    yellow "SwiftBar is not installed. Install with:"
    yellow "    brew install --cask swiftbar"
    yellow "Then launch SwiftBar.app and point its plugin directory at:"
    yellow "    ${PLUGIN_DIR}"
fi

green "Install complete."
exit 0
