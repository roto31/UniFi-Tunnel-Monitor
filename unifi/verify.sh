#!/bin/bash
# =============================================================================
# verify.sh — post-install sanity check (UniFi gateway)
# =============================================================================
# Run on the gateway AFTER bash install.sh (and after editing config.env).
#
#     bash verify.sh
# =============================================================================

set -u

TARGET_DIR="/data/tunnel-monitor"
SYSTEMD_DIR="/etc/systemd/system"
PASS=0
FAIL=0

green() { printf '  PASS %s\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
yellow(){ printf '  WARN %s\n' "$*"; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
verify.sh — sanity check the UniFi tunnel-monitor install

USAGE
    bash verify.sh

EXIT
    0  all checks passed
    1  one or more checks failed
EOF
    exit 0
fi

if [[ -x "${TARGET_DIR}/heal.sh" ]]; then
    green "heal.sh present and executable"
else
    red "heal.sh missing or not executable at ${TARGET_DIR}/heal.sh"
fi

if [[ -f "${TARGET_DIR}/heal-state" && -w "${TARGET_DIR}/heal-state" ]]; then
    green "heal-state present and writable"
else
    red "heal-state missing or not writable"
fi

if [[ -f "${TARGET_DIR}/heal.log" && -w "${TARGET_DIR}/heal.log" ]]; then
    green "heal.log present and writable"
else
    red "heal.log missing or not writable"
fi

if [[ -f "${TARGET_DIR}/config.env" ]]; then
    missing=0
    for k in HEAL_ENABLED HEAL_DRY_RUN HEAL_ON_FIRST_FAILURE HEAL_MAX_ATTEMPTS \
             HEAL_COOLDOWN_MINUTES HEAL_MAX_PER_DAY HEAL_CMD_TIMEOUT \
             HEAL_TOTAL_TIMEOUT HEAL_SETTLE_SECONDS HEAL_ALLOW_DAEMON_RESTART \
             HEAL_NOTIFY_ON_SUCCESS; do
        if ! grep -q "^${k}=" "${TARGET_DIR}/config.env"; then
            yellow "config.env missing ${k} (defaults apply in heal.sh / monitor.sh)"
            missing=1
        fi
    done
    if [[ "${missing}" -eq 0 ]]; then
        green "config.env contains HEAL_* keys"
    fi
else
    red "config.env missing"
fi

if [[ -x "${TARGET_DIR}/tunnel-check" ]]; then
    if "${TARGET_DIR}/tunnel-check" --heal-status >/dev/null 2>&1; then
        green "tunnel-check --heal-status exits 0"
    else
        red "tunnel-check --heal-status failed"
    fi
else
    red "tunnel-check missing"
fi

if [[ -f "${SYSTEMD_DIR}/tunnel-monitor.service" ]]; then
    green "systemd unit present"
else
    yellow "systemd unit missing — re-run install.sh"
fi

if [[ -f "${TARGET_DIR}/state" ]]; then
    green "monitor state file present"
else
    red "state file missing"
fi

echo
echo "Passed: ${PASS}  Failed: ${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
