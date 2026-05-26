#!/bin/bash
# =============================================================================
# Deploy tunnel-monitor to a remote (spoke) UniFi gateway from the hub or any
# host that can SSH to the spoke over the site-to-site VPN.
#
# Usage:
#   export PUBLIC_UNIFI_SRC="/path/to/UniFi-Tunnel-Monitor/unifi"
#   export SPOKE_GATEWAY_LAN_IP="REPLACE_WITH_SPOKE_GATEWAY_LAN_IP"
#   bash deploy-from-hub.sh
#
# Optional:
#   SPOKE_SSH_USER=root
#   SPOKE_SSH_KEY=~/.ssh/id_ed25519
#   SPOKE_HOST=...   # alias for SPOKE_GATEWAY_LAN_IP
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOKE_HOST="${SPOKE_HOST:-${SPOKE_GATEWAY_LAN_IP:-}}"
SPOKE_USER="${SPOKE_SSH_USER:-root}"
SPOKE_SSH_KEY="${SPOKE_SSH_KEY:-}"
PUBLIC_UNIFI_SRC="${PUBLIC_UNIFI_SRC:-}"

if [[ -z "${SPOKE_HOST}" ]]; then
    echo "ERROR: Set SPOKE_GATEWAY_LAN_IP (or SPOKE_HOST) to the spoke gateway LAN IP." >&2
    exit 2
fi

if [[ -z "${PUBLIC_UNIFI_SRC}" ]]; then
    echo "ERROR: Set PUBLIC_UNIFI_SRC to the unifi/ directory from this repo." >&2
    exit 2
fi

if [[ ! -f "${PUBLIC_UNIFI_SRC}/install.sh" ]]; then
    echo "ERROR: ${PUBLIC_UNIFI_SRC}/install.sh not found." >&2
    exit 2
fi

ssh_args=(-o "StrictHostKeyChecking=accept-new")
if [[ -n "${SPOKE_SSH_KEY}" ]]; then
    ssh_args+=(-i "${SPOKE_SSH_KEY}")
fi

remote="${SPOKE_USER}@${SPOKE_HOST}"

echo "==> Copying unifi/ to ${remote}:/root/tunnel-monitor-src"
scp "${ssh_args[@]}" -r "${PUBLIC_UNIFI_SRC}/" "${remote}:/root/tunnel-monitor-src/"

echo "==> Copying spoke config template"
scp "${ssh_args[@]}" "${SCRIPT_DIR}/config.env.template" \
    "${remote}:/root/tunnel-monitor-src/spoke-config.env.template"

echo "==> Running install.sh on spoke gateway"
ssh "${ssh_args[@]}" "${remote}" bash <<'REMOTE'
set -euo pipefail
cd /root/tunnel-monitor-src
bash install.sh
if [[ ! -s /data/tunnel-monitor/config.env ]] || grep -q 'REPLACE_WITH_' /data/tunnel-monitor/config.env 2>/dev/null; then
    if [[ -f spoke-config.env.template ]]; then
        install -m 0600 spoke-config.env.template /data/tunnel-monitor/config.env
        echo "==> Installed spoke config.env.template (edit SMTP_PASSWORD on gateway)"
    fi
fi
REMOTE

cat <<EOF

==> Deploy complete.

Next on spoke gateway:
  ssh ${remote}
  nano /data/tunnel-monitor/config.env
  tunnel-check --test-email
  tunnel-check
  systemctl list-timers tunnel-monitor.timer

See docs/spoke-monitoring.md in this repo.

EOF
