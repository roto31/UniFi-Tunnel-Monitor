#!/bin/bash
# =============================================================================
# verify.sh — post-install sanity check
# =============================================================================
# Run AFTER `sudo bash install.sh` (and after editing config.env). All-green
# means the install is good; any red means something needs attention.
#
#     sudo bash verify.sh
# =============================================================================

set -uo pipefail

INSTALL_DIR="/opt/tunnel-monitor"
LAUNCHD_LABEL="com.example.tunnel-monitor"
PLIST_DEST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
SYMLINK_DEST="/usr/local/bin/tunnel-check"
SSH_KEY="${INSTALL_DIR}/.ssh/id_ed25519"
CONFIG_FILE="${INSTALL_DIR}/config.env"
STATE_FILE="${INSTALL_DIR}/state.json"

PASS=0
FAIL=0

green() { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
yellow(){ printf '\033[1;33m  WARN\033[0m %s\n' "$*"; }
hdr()   { printf '\n\033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
verify.sh — sanity check the tunnel-monitor install

USAGE
    sudo bash verify.sh

EXIT
    0  all checks passed
    1  one or more checks failed
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
    yellow "Some checks (perms, launchctl) need root. Re-running under sudo..."
    exec sudo bash "${BASH_SOURCE[0]}" "$@"
fi

INVOKER_USER="${SUDO_USER:-}"
if [[ -z "${INVOKER_USER}" || "${INVOKER_USER}" == "root" ]]; then
    INVOKER_USER="$(stat -f "%Su" /dev/console 2>/dev/null || echo "")"
fi
INVOKER_HOME=""
[[ -n "${INVOKER_USER}" && "${INVOKER_USER}" != "root" ]] && INVOKER_HOME="$(eval echo "~${INVOKER_USER}")"

# -----------------------------------------------------------------------------

check_file() {
    local path="$1" expected_mode="$2" expected_owner="${3:-root:wheel}"
    if [[ ! -e "${path}" ]]; then
        red "missing: ${path}"
        return
    fi
    local mode owner group ownerstr
    mode="$(stat -f "%Lp" "${path}")"
    owner="$(stat -f "%Su" "${path}")"
    group="$(stat -f "%Sg" "${path}")"
    ownerstr="${owner}:${group}"
    if [[ "${mode}" != "${expected_mode}" ]]; then
        red "${path} has mode ${mode}, expected ${expected_mode}"
        return
    fi
    if [[ "${ownerstr}" != "${expected_owner}" ]]; then
        red "${path} owned by ${ownerstr}, expected ${expected_owner}"
        return
    fi
    green "${path} (${mode}, ${ownerstr})"
}

# -----------------------------------------------------------------------------

hdr "1. /opt/tunnel-monitor/ permissions"

check_file "${INSTALL_DIR}"                     "755"
check_file "${INSTALL_DIR}/monitor.sh"          "755"
check_file "${INSTALL_DIR}/notify.sh"           "755"
check_file "${INSTALL_DIR}/tunnel-check"        "755"
check_file "${INSTALL_DIR}/send-email.sh"       "750"
check_file "${INSTALL_DIR}/ssh-router-state.sh"   "750"
check_file "${INSTALL_DIR}/config.env"          "600"
check_file "${INSTALL_DIR}/config.env.template" "644"
check_file "${INSTALL_DIR}/state.json"          "644"
check_file "${INSTALL_DIR}/.ssh"                "700"
check_file "${SSH_KEY}"                         "600"

# -----------------------------------------------------------------------------

hdr "2. CLI symlink"

if [[ -L "${SYMLINK_DEST}" ]]; then
    target="$(readlink "${SYMLINK_DEST}")"
    if [[ "${target}" == "${INSTALL_DIR}/tunnel-check" ]]; then
        green "${SYMLINK_DEST} -> ${target}"
    else
        red "${SYMLINK_DEST} points to ${target}, expected ${INSTALL_DIR}/tunnel-check"
    fi
else
    red "${SYMLINK_DEST} symlink missing"
fi

# -----------------------------------------------------------------------------

hdr "3. LaunchDaemon"

check_file "${PLIST_DEST}" "644"

if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    green "launchctl: system/${LAUNCHD_LABEL} is loaded"
else
    red "launchctl: system/${LAUNCHD_LABEL} is NOT loaded (try: sudo launchctl bootstrap system ${PLIST_DEST})"
fi

# -----------------------------------------------------------------------------

hdr "4. Config has a real password set"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    (
        set +u
        source "${CONFIG_FILE}" 2>/dev/null
        if [[ -z "${SMTP_PASSWORD:-}" || "${SMTP_PASSWORD:-}" == "REPLACE_WITH_APP_SPECIFIC_PASSWORD" ]]; then
            exit 1
        fi
        exit 0
    )
    if [[ $? -eq 0 ]]; then
        green "SMTP_PASSWORD is set (non-template)"
    else
        red "SMTP_PASSWORD is empty or still the placeholder — edit ${CONFIG_FILE}"
    fi
else
    red "config.env missing"
fi

# -----------------------------------------------------------------------------

hdr "5. state.json is valid JSON and was updated by a real run"

if [[ -f "${STATE_FILE}" ]]; then
    if jq -e . "${STATE_FILE}" >/dev/null 2>&1; then
        green "state.json is valid JSON"
        diagnosis="$(jq -r '.diagnosis' "${STATE_FILE}")"
        case "${diagnosis}" in
            HEALTHY|TUNNEL_DOWN|DDNS_DRIFT|REMOTE_INTERNET_DOWN|router_UNREACHABLE|DISAGREEMENT|OUR_INTERNET_DOWN)
                green "state.json shows a real diagnosis: ${diagnosis}"
                ;;
            PENDING_FIRST_RUN|RESET)
                yellow "state.json shows ${diagnosis} — daemon hasn't run a real check yet"
                yellow "    Try: sudo tunnel-check --check-now"
                ;;
            *)
                yellow "state.json diagnosis is unexpected: ${diagnosis}"
                ;;
        esac
    else
        red "state.json is NOT valid JSON"
    fi
else
    red "state.json missing"
fi

# -----------------------------------------------------------------------------

hdr "6. SSH dedup key works"

if [[ -x "${INSTALL_DIR}/ssh-router-state.sh" ]]; then
    if line="$("${INSTALL_DIR}/ssh-router-state.sh" 2>/dev/null)"; then
        green "SSH-based router-side dedup works (state line: ${line})"
    else
        red "SSH to router failed (run: sudo /opt/tunnel-monitor/ssh-router-state.sh to see why)"
    fi
else
    red "${INSTALL_DIR}/ssh-router-state.sh missing or not executable"
fi

# -----------------------------------------------------------------------------

hdr "7. SwiftBar plugin in place"

if [[ -n "${INVOKER_HOME}" ]]; then
    PLUGIN_DIR=""
    if PD="$(sudo -u "${INVOKER_USER}" defaults read com.ainvyu.SwiftBar PluginDirectory 2>/dev/null)"; then
        PLUGIN_DIR="${PD/#\~/${INVOKER_HOME}}"
    fi
    [[ -z "${PLUGIN_DIR}" ]] && PLUGIN_DIR="${INVOKER_HOME}/Library/Application Support/SwiftBar/Plugins"
    PLUGIN_FILE="${PLUGIN_DIR}/tunnel-monitor.30s.sh"
    if [[ -f "${PLUGIN_FILE}" ]]; then
        green "SwiftBar plugin installed: ${PLUGIN_FILE}"
        if [[ ! -d "/Applications/SwiftBar.app" ]]; then
            yellow "SwiftBar.app not installed — install with: brew install --cask swiftbar"
        fi
    else
        red "SwiftBar plugin missing at ${PLUGIN_FILE}"
    fi
else
    yellow "Could not determine invoking user's home — skipping SwiftBar plugin check"
fi

# -----------------------------------------------------------------------------

hdr "8. monitor.log exists and is being written"

if [[ -f "${INSTALL_DIR}/monitor.log" ]]; then
    if [[ -s "${INSTALL_DIR}/monitor.log" ]]; then
        green "monitor.log has content (last line shown below)"
        tail -1 "${INSTALL_DIR}/monitor.log" | sed 's/^/    /'
    else
        yellow "monitor.log exists but is empty — try: sudo tunnel-check --check-now"
    fi
else
    red "monitor.log missing"
fi

# -----------------------------------------------------------------------------

hdr "Summary"
printf '  PASS: %d\n' "${PASS}"
printf '  FAIL: %d\n' "${FAIL}"

if (( FAIL == 0 )); then
    printf '\n\033[1;32mAll green. Install verified.\033[0m\n'
    exit 0
fi
printf '\n\033[1;31m%d check(s) failed. See above.\033[0m\n' "${FAIL}"
exit 1
