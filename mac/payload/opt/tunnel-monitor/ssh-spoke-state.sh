#!/bin/bash
# =============================================================================
# ssh-spoke-state.sh — read the spoke policy-route state and observed WAN IP
# =============================================================================
# Prints exactly two lines on success:
#   1. policy-state line ("N:UP" / "N:DOWN") or MISSING
#   2. spoke public IPv4, or UNKNOWN
#
# Exit codes:
#   0  success (two validated lines printed)
#   1  SSH failure or unparseable output
#   2  config error (missing config.env, host, or key)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

show_help() {
    cat <<'EOF'
ssh-spoke-state.sh — read spoke policy-route state and observed public IP

USAGE
    ssh-spoke-state.sh
    ssh-spoke-state.sh --help

OUTPUT
    Line 1: policy-state ("0:UP", "3:DOWN") or MISSING if the file is absent
    Line 2: spoke public IPv4 from https://api.ipify.org, or UNKNOWN

CONFIG
    SPOKE_HOST, SPOKE_USER, SPOKE_KEY, SPOKE_POLICY_STATE_PATH in config.env.
    One SSH session, BatchMode, ConnectTimeout=5.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config file missing: ${CONFIG_FILE}" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

SPOKE_HOST="${SPOKE_HOST:-}"
SPOKE_USER="${SPOKE_USER:-root}"
SPOKE_KEY="${SPOKE_KEY:-/opt/tunnel-monitor/.ssh/id_ed25519}"
SPOKE_POLICY_STATE_PATH="${SPOKE_POLICY_STATE_PATH:-/data/tunnel-monitor/policy-state}"

if [[ -z "${SPOKE_HOST}" || "${SPOKE_HOST}" == REPLACE_WITH_* ]]; then
    echo "ERROR: set SPOKE_HOST in ${CONFIG_FILE}" >&2
    exit 2
fi

if [[ ! -f "${SPOKE_KEY}" ]]; then
    echo "ERROR: SSH key missing: ${SPOKE_KEY}" >&2
    exit 2
fi

if [[ ! "${SPOKE_POLICY_STATE_PATH}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "ERROR: SPOKE_POLICY_STATE_PATH is not a safe absolute path" >&2
    exit 2
fi

is_ipv4() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local oct
    for oct in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        if (( 10#${oct} > 255 )); then
            return 1
        fi
    done
    return 0
}

# Path is restricted to a safe character set above, so it is quoted in the remote shell.
remote_script="$(cat <<EOF
if [ -f '${SPOKE_POLICY_STATE_PATH}' ]; then
  tr -d '[:space:]' < '${SPOKE_POLICY_STATE_PATH}'
  printf '\\n'
else
  echo MISSING
fi
ip=\$(curl -s -m 4 https://api.ipify.org 2>/dev/null || true)
ip=\$(printf '%s' "\$ip" | tr -d '[:space:]')
if [ -z "\$ip" ]; then
  echo UNKNOWN
else
  printf '%s\\n' "\$ip"
fi
EOF
)"

raw="$(
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=2 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${SCRIPT_DIR}/.ssh/known_hosts" \
        -i "${SPOKE_KEY}" \
        "${SPOKE_USER}@${SPOKE_HOST}" \
        "${remote_script}" 2>/dev/null
)" || {
    echo "ERROR: ssh to ${SPOKE_USER}@${SPOKE_HOST} failed" >&2
    exit 1
}

line1="$(printf '%s\n' "${raw}" | sed -n '1p' | tr -d '[:space:]')"
line2="$(printf '%s\n' "${raw}" | sed -n '2p' | tr -d '[:space:]')"
extra="$(printf '%s\n' "${raw}" | sed -n '3p' | tr -d '[:space:]')"

if [[ -n "${extra}" ]]; then
    echo "ERROR: spoke SSH returned more than two lines" >&2
    exit 1
fi

if [[ ! "${line1}" =~ ^[0-9]+:(UP|DOWN)$ && "${line1}" != "MISSING" ]]; then
    echo "ERROR: policy-state line malformed: '${line1}'" >&2
    exit 1
fi

if [[ "${line2}" != "UNKNOWN" ]] && ! is_ipv4 "${line2}"; then
    echo "ERROR: observed WAN malformed: '${line2}'" >&2
    exit 1
fi

printf '%s\n' "${line1}"
printf '%s\n' "${line2}"
exit 0
