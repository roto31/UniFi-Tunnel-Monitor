#!/bin/bash
# =============================================================================
# install.sh — idempotent installer for the Linux tunnel monitor
# =============================================================================
# Run from the linux/ folder:
#     sudo bash install.sh
# Re-running is safe and never destroys config.env or state.json.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${REPO_DIR}/payload"
SRC_OPT="${PAYLOAD_DIR}/opt/tunnel-monitor"
SRC_SVC="${PAYLOAD_DIR}/etc/systemd/system/tunnel-monitor.service"
SRC_TMR="${PAYLOAD_DIR}/etc/systemd/system/tunnel-monitor.timer"

INSTALL_DIR="/opt/tunnel-monitor"
SSH_DIR="${INSTALL_DIR}/.ssh"
SSH_KEY="${SSH_DIR}/id_ed25519"
SSH_PUB="${SSH_KEY}.pub"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_UNIT="tunnel-monitor.service"
TIMER_UNIT="tunnel-monitor.timer"
SYMLINK_DEST="/usr/local/bin/tunnel-check"

ROUTER_HOST_DEFAULT="REPLACE_WITH_ROUTER_LAN_IP"
ROUTER_USER_DEFAULT="root"

bold()  { printf '\033[1m%s\033[0m\n'    "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
install.sh — installer for the Linux tunnel monitor

USAGE
    sudo bash install.sh
    bash install.sh --help

Re-runs are safe: config.env and state.json are preserved.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

step "Phase 1 — Preflight"

if [[ "$(uname -s)" != "Linux" ]]; then
    red "ERROR: this installer only runs on Linux."
    exit 3
fi

if [[ ${EUID} -ne 0 ]]; then
    yellow "Re-executing under sudo..."
    exec sudo --preserve-env=SUDO_USER bash "${BASH_SOURCE[0]}" "$@"
fi

if ! command -v systemctl >/dev/null 2>&1; then
    red "ERROR: systemctl not found — systemd is required."
    exit 3
fi

for required in \
    "${SRC_OPT}/monitor.sh" \
    "${SRC_OPT}/send-email.sh" \
    "${SRC_OPT}/notify.sh" \
    "${SRC_OPT}/tunnel-check" \
    "${SRC_OPT}/ssh-router-state.sh" \
    "${SRC_OPT}/config.env.template" \
    "${SRC_SVC}" \
    "${SRC_TMR}"
do
    if [[ ! -f "${required}" ]]; then
        red "ERROR: missing payload file: ${required}"
        exit 1
    fi
done
green "Payload looks complete."

for c in jq curl dig ssh ssh-keygen ping; do
    if ! command -v "$c" >/dev/null 2>&1; then
        red "ERROR: missing required command: ${c}"
        red "       Install via your distro (e.g. apt install jq curl dnsutils openssh-client iputils-ping)."
        exit 3
    fi
done
green "All required commands present."

step "Phase 2 — Install /opt/tunnel-monitor"

mkdir -p "${INSTALL_DIR}"
chown root:root "${INSTALL_DIR}"
chmod 0755 "${INSTALL_DIR}"

install_file() {
    local src="$1" dest="$2" mode="$3"
    install -m "${mode}" -o root -g root "${src}" "${dest}"
    green "Installed ${dest} (mode ${mode})"
}

install_file "${SRC_OPT}/monitor.sh"          "${INSTALL_DIR}/monitor.sh"          0755
install_file "${SRC_OPT}/notify.sh"           "${INSTALL_DIR}/notify.sh"           0755
install_file "${SRC_OPT}/tunnel-check"        "${INSTALL_DIR}/tunnel-check"        0755
install_file "${SRC_OPT}/send-email.sh"       "${INSTALL_DIR}/send-email.sh"       0750
install_file "${SRC_OPT}/ssh-router-state.sh" "${INSTALL_DIR}/ssh-router-state.sh" 0750
install_file "${SRC_OPT}/config.env.template" "${INSTALL_DIR}/config.env.template" 0644

if [[ -f "${INSTALL_DIR}/config.env" ]]; then
    yellow "config.env already exists — leaving it untouched."
    chmod 0600 "${INSTALL_DIR}/config.env"
    chown root:root "${INSTALL_DIR}/config.env"
else
    install -m 0600 -o root -g root "${SRC_OPT}/config.env.template" "${INSTALL_DIR}/config.env"
    yellow "Wrote starter config.env from template — edit SMTP_PASSWORD before testing."
fi

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
    chown root:root "${INSTALL_DIR}/state.json"
    green "Initialized state.json with PENDING_FIRST_RUN."
else
    yellow "state.json already present — leaving it untouched."
fi

touch "${INSTALL_DIR}/monitor.log"
chmod 0644 "${INSTALL_DIR}/monitor.log"
chown root:root "${INSTALL_DIR}/monitor.log"

if [[ -L "${SYMLINK_DEST}" || -e "${SYMLINK_DEST}" ]]; then
    rm -f "${SYMLINK_DEST}"
fi
mkdir -p "$(dirname "${SYMLINK_DEST}")"
ln -s "${INSTALL_DIR}/tunnel-check" "${SYMLINK_DEST}"
green "Symlinked ${SYMLINK_DEST} -> ${INSTALL_DIR}/tunnel-check"

step "Phase 3 — SSH key for router-side dedup"

mkdir -p "${SSH_DIR}"
chown root:root "${SSH_DIR}"
chmod 0700 "${SSH_DIR}"

if [[ -f "${SSH_KEY}" ]]; then
    green "SSH key already exists at ${SSH_KEY} — keeping it."
else
    yellow "Generating new ed25519 key..."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "tunnel-monitor@$(hostname -s)" >/dev/null
    green "Generated ${SSH_KEY}"
fi
chown root:root "${SSH_KEY}" "${SSH_PUB}"
chmod 0600 "${SSH_KEY}"
chmod 0644 "${SSH_PUB}"

ROUTER_HOST="${ROUTER_HOST_DEFAULT}"
ROUTER_USER="${ROUTER_USER_DEFAULT}"
if [[ -f "${INSTALL_DIR}/config.env" ]]; then
    # shellcheck disable=SC1090
    source "${INSTALL_DIR}/config.env" >/dev/null 2>&1 || true
    ROUTER_HOST="${ROUTER_HOST:-${ROUTER_HOST_DEFAULT}}"
    ROUTER_USER="${ROUTER_USER:-${ROUTER_USER_DEFAULT}}"
fi

SKIP_ROUTER_AUTH=0
if [[ "${ROUTER_HOST}" == "REPLACE_WITH_ROUTER_LAN_IP" ]]; then
    yellow "Skipping router SSH key authorization (ROUTER_HOST is still placeholder)."
    SKIP_ROUTER_AUTH=1
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
    :
elif test_router_key; then
    green "SSH key already authorized on ${ROUTER_USER}@${ROUTER_HOST}."
else
    yellow "Pushing pubkey to router (router password requested once)..."
    if ! cat "${SSH_PUB}" | ssh \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${SSH_DIR}/known_hosts" \
            "${ROUTER_USER}@${ROUTER_HOST}" \
            'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'
    then
        red "ERROR: ssh-copy equivalent failed."
        exit 1
    fi
    test_router_key && green "SSH key authorized." || { red "ERROR: key still not authenticating."; exit 1; }
fi

chmod 0600 "${SSH_DIR}/known_hosts" 2>/dev/null || true
chown root:root "${SSH_DIR}/known_hosts" 2>/dev/null || true

step "Phase 4 — systemd"

install -m 0644 -o root -g root "${SRC_SVC}" "${SYSTEMD_DIR}/${SERVICE_UNIT}"
install -m 0644 -o root -g root "${SRC_TMR}" "${SYSTEMD_DIR}/${TIMER_UNIT}"
systemctl daemon-reload
systemctl enable --now "${TIMER_UNIT}"
green "Enabled and started ${TIMER_UNIT}."

step "Phase 5 — Done"

bold "Next steps:"
cat <<EOF
  sudo vi ${INSTALL_DIR}/config.env
  tunnel-check --test-email
  sudo tunnel-check --check-now
  sudo bash ${REPO_DIR}/verify.sh
EOF

green "Install complete."
