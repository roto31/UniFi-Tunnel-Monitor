#!/bin/bash
# =============================================================================
# Deploy tunnel-monitor Mac payload on a remote-site LAN Mac.
# Run ON the remote Mac (or via SSH to it), not on the hub Mac.
#
# Usage (on remote Mac):
#   export PUBLIC_MAC_SRC="/path/to/UniFi-Tunnel-Monitor/mac"
#   sudo bash deploy-from-remote.sh
#
# Prerequisites:
#   - Site-to-site VPN up (ping hub LAN gateway works)
#   - Spoke gateway monitor installed (recommended for dedup)
# =============================================================================

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash $0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_MAC_SRC="${PUBLIC_MAC_SRC:-}"

if [[ -z "${PUBLIC_MAC_SRC}" ]]; then
    echo "ERROR: Set PUBLIC_MAC_SRC to the mac/ directory from this repo." >&2
    exit 2
fi

if [[ ! -f "${PUBLIC_MAC_SRC}/install.sh" ]]; then
    echo "ERROR: ${PUBLIC_MAC_SRC}/install.sh not found." >&2
    exit 2
fi

echo "==> Running mac/install.sh"
cd "${PUBLIC_MAC_SRC}"
bash install.sh

TARGET="/opt/tunnel-monitor/config.env"
if [[ ! -f "${TARGET}" ]] || grep -q 'REPLACE_WITH_' "${TARGET}" 2>/dev/null; then
    install -m 0600 "${SCRIPT_DIR}/config.env.template" "${TARGET}"
    echo "==> Installed spoke config.env.template (edit SMTP_PASSWORD)"
fi

if [[ -f /opt/tunnel-monitor/.ssh/id_ed25519.pub ]]; then
    echo "==> Add this public key to spoke gateway root authorized_keys if not already:"
    cat /opt/tunnel-monitor/.ssh/id_ed25519.pub
    echo
    echo "  ssh root@REPLACE_WITH_SPOKE_GATEWAY_LAN_IP 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys'"
fi

cat <<EOF

==> Install complete.

Next:
  sudo nano /opt/tunnel-monitor/config.env
  tunnel-check --test-email
  tunnel-check --ssh-test
  tunnel-check

See docs/spoke-monitoring.md in this repo.

EOF
