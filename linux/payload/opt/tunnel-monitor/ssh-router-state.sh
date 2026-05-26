#!/bin/bash
# =============================================================================
# ssh-router-state.sh - read the ROUTER monitor's state file via SSH for dedup
# =============================================================================
# Prints the ROUTER state line ("N:UP" / "N:DOWN") to stdout on success.
# Exits non-zero if SSH fails, the key is unauthorized, or the remote file is
# missing - monitor.sh treats any non-zero exit as "ROUTER unreachable".
#
# Exit codes:
#   0  success (state line printed)
#   1  ssh failure or empty/unparseable remote state
#   2  config error (missing config.env or required vars)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

show_help() {
    cat <<'EOF'
ssh-router-state.sh - read ROUTER tunnel-monitor state for dedup decisions

USAGE
    ssh-router-state.sh
    ssh-router-state.sh --help

OUTPUT
    Prints the ROUTER state line (e.g. "0:UP", "3:DOWN") to stdout. Exits
    non-zero if SSH fails or the remote file is missing.

CONFIG
    Reads ROUTER_HOST, ROUTER_USER, ROUTER_KEY, ROUTER_STATE_PATH from config.env.
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

# NOTE: the fallback defaults below are RFC-5737 documentation IPs and will
# never connect to a real network. Set ROUTER_HOST / ROUTER_USER in config.env
# before installing. See PLACEHOLDERS.md for the canonical value reference.
ROUTER_HOST="${ROUTER_HOST:-192.0.2.254}"
ROUTER_USER="${ROUTER_USER:-root}"
ROUTER_KEY="${ROUTER_KEY:-/opt/tunnel-monitor/.ssh/id_ed25519}"
ROUTER_STATE_PATH="${ROUTER_STATE_PATH:-/data/tunnel-monitor/state}"

if [[ ! -f "${ROUTER_KEY}" ]]; then
    echo "ERROR: SSH key missing: ${ROUTER_KEY}" >&2
    exit 2
fi

state_line="$(
    ssh -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=2 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${SCRIPT_DIR}/.ssh/known_hosts" \
        -i "${ROUTER_KEY}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "cat ${ROUTER_STATE_PATH} 2>/dev/null" 2>/dev/null
)" || {
    echo "ERROR: ssh to ${ROUTER_USER}@${ROUTER_HOST} failed" >&2
    exit 1
}

state_line="$(printf '%s' "${state_line}" | tr -d '[:space:]')"

if [[ -z "${state_line}" ]]; then
    echo "ERROR: ROUTER state file empty or missing" >&2
    exit 1
fi

if [[ ! "${state_line}" =~ ^[0-9]+:(UP|DOWN)$ ]]; then
    echo "ERROR: ROUTER state line malformed: '${state_line}'" >&2
    exit 1
fi

printf '%s\n' "${state_line}"
exit 0
