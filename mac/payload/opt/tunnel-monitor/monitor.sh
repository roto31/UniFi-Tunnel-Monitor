#!/bin/bash
# =============================================================================
# the remote site Tunnel Monitor — Mac edition
# =============================================================================
# A SECOND vantage point for the the local site <-> the remote site site-to-site VPN.
# A sibling monitor on the ROUTER watches the tunnel from the router; this one
# watches it from a LAN client (the Mac) so we catch the failure mode
# where "the router thinks it's fine but the Mac can't reach anything."
#
# Behaviour:
#   * Runs every 5 minutes via /Library/LaunchDaemons/com.example.tunnel-monitor.plist
#   * Pings tunnel target, remote WAN, our internet; resolves remote DDNS
#   * Maintains a JSON state machine in /opt/tunnel-monitor/state.json
#   * After FAILURE_THRESHOLD consecutive failures, sends email + banner
#   * Suppresses the email (but never the banner) when the ROUTER has already
#     alerted, deduping via SSH read of /data/tunnel-monitor/state on ROUTER
#   * Sends a recovery email + banner when the tunnel comes back up
#   * Always exits 0 so launchd never throttles us — internal failures are
#     logged to /opt/tunnel-monitor/monitor.log
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
STATE_FILE="${SCRIPT_DIR}/state.json"
LOG_FILE="${SCRIPT_DIR}/monitor.log"
LOG_MAX_BYTES=$((1 * 1024 * 1024))

SEND_EMAIL_BIN="${SCRIPT_DIR}/send-email.sh"
NOTIFY_BIN="${SCRIPT_DIR}/notify.sh"
SSH_ROUTER_BIN="${SCRIPT_DIR}/ssh-router-state.sh"
SSH_SPOKE_BIN="${SCRIPT_DIR}/ssh-spoke-state.sh"
ADVISORIES_PREV_FILE="${SCRIPT_DIR}/advisories.prev"

SPOKE_POLICY_ENABLED=false
SPOKE_POLICY_LABEL="Spoke policy route"

# -----------------------------------------------------------------------------
# Help / subcommand dispatch
# -----------------------------------------------------------------------------

show_help() {
    cat <<'EOF'
monitor.sh — tunnel health check + state machine + alert decision

USAGE
    monitor.sh                 # full check (default; called by launchd)
    monitor.sh check           # alias for default
    monitor.sh diagnose        # run checks and print diagnosis only (no state writes)
    monitor.sh notify-test     # send a synthetic banner via notify.sh
    monitor.sh email-test      # send a synthetic email via send-email.sh
    monitor.sh ssh-test        # invoke ssh-router-state.sh and print result
    monitor.sh --help

EXIT
    Always 0 from the default check path so launchd never throttles.
EOF
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

rotate_log_if_needed() {
    [[ -f "${LOG_FILE}" ]] || return 0
    local size
    size="$(stat -f "%z" "${LOG_FILE}" 2>/dev/null || echo 0)"
    if (( size > LOG_MAX_BYTES )); then
        mv "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
        : > "${LOG_FILE}"
        chmod 0644 "${LOG_FILE}" 2>/dev/null || true
    fi
}

log() {
    local level="$1"; shift
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    printf '%s\n' "${line}"
}

log_info()  { log "INFO"  "$*"; }
log_warn()  { log "WARN"  "$*" >&2; }
log_error() { log "ERROR" "$*" >&2; }

# Catch any unexpected error; we log and force exit 0 so launchd is happy.
on_unexpected_exit() {
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        log_error "monitor.sh exited unexpectedly (rc=${rc})"
    fi
}
trap on_unexpected_exit EXIT

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "config file missing: ${CONFIG_FILE}"
        exit 0
    fi
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    REMOTE_LAN_IP="${REMOTE_LAN_IP:-192.0.2.1}"
    REMOTE_WAN_IP="${REMOTE_WAN_IP:-198.51.100.1}"
    REMOTE_DDNS="${REMOTE_DDNS:-remote.example.com}"
    FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
    PING_COUNT="${PING_COUNT:-3}"
    PING_TIMEOUT="${PING_TIMEOUT:-2}"
    SUBJECT_PREFIX="${SUBJECT_PREFIX:-[MAC]}"
    NOTIFY_SOUND_DOWN="${NOTIFY_SOUND_DOWN:-Glass}"
    NOTIFY_SOUND_RECOVERY="${NOTIFY_SOUND_RECOVERY:-Hero}"

    # Spoke policy-route visibility is opt-in. Off matches 1.3.1 behavior.
    SPOKE_POLICY_ENABLED="${SPOKE_POLICY_ENABLED:-false}"
    SPOKE_HOST="${SPOKE_HOST:-}"
    SPOKE_USER="${SPOKE_USER:-root}"
    SPOKE_KEY="${SPOKE_KEY:-/opt/tunnel-monitor/.ssh/id_ed25519}"
    SPOKE_POLICY_STATE_PATH="${SPOKE_POLICY_STATE_PATH:-/data/tunnel-monitor/policy-state}"
    SPOKE_POLICY_LABEL="${SPOKE_POLICY_LABEL:-Spoke policy route}"
}

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "missing dependency: $1"
        return 1
    fi
}

ensure_dependencies() {
    local missing=0
    for c in jq dig ping curl ssh; do
        require_cmd "$c" || missing=1
    done
    return "${missing}"
}

# -----------------------------------------------------------------------------
# Health checks
# -----------------------------------------------------------------------------

# Globals populated by run_health_checks (kept simple — no namespace pollution
# beyond what's helpful).
OK_TUNNEL=false
OK_REMOTE_WAN=false
OK_OUR_INTERNET=false
OK_DNS_MATCH=false

LATENCY_TUNNEL=""
LATENCY_REMOTE_WAN=""
LATENCY_OUR_INTERNET=""
DNS_RESOLVED=""

# Ping a target. On success, prints avg latency in ms to stdout.
# Exit 0 on success, non-zero on failure. macOS `ping -W` is in milliseconds.
ping_avg_ms() {
    local target="$1"
    local timeout_ms=$(( PING_TIMEOUT * 1000 ))
    local output
    if ! output="$(ping -c "${PING_COUNT}" -W "${timeout_ms}" -q "${target}" 2>/dev/null)"; then
        return 1
    fi
    local avg
    avg="$(printf '%s' "${output}" | awk -F'/' '/round-trip|rtt/ {print $5}' | head -1)"
    if [[ -z "${avg}" ]]; then
        printf '0'
    else
        printf '%s' "${avg}"
    fi
}

resolve_ddns() {
    # Try Cloudflare first, fall back to system resolver, then to Google.
    local r=""
    r="$(dig +short +time=3 +tries=1 "${REMOTE_DDNS}" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
    if [[ -z "${r}" ]]; then
        r="$(dig +short +time=3 +tries=1 "${REMOTE_DDNS}" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
    fi
    if [[ -z "${r}" ]]; then
        r="$(dig +short +time=3 +tries=1 "${REMOTE_DDNS}" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
    fi
    printf '%s' "${r}"
}

run_health_checks() {
    OK_TUNNEL=false; OK_REMOTE_WAN=false; OK_OUR_INTERNET=false; OK_DNS_MATCH=false
    LATENCY_TUNNEL=""; LATENCY_REMOTE_WAN=""; LATENCY_OUR_INTERNET=""; DNS_RESOLVED=""

    if LATENCY_TUNNEL="$(ping_avg_ms "${REMOTE_LAN_IP}")"; then OK_TUNNEL=true; fi
    if LATENCY_REMOTE_WAN="$(ping_avg_ms "${REMOTE_WAN_IP}")"; then OK_REMOTE_WAN=true; fi
    if LATENCY_OUR_INTERNET="$(ping_avg_ms 1.1.1.1)"; then OK_OUR_INTERNET=true; fi

    DNS_RESOLVED="$(resolve_ddns)"
    if [[ -n "${DNS_RESOLVED}" && "${DNS_RESOLVED}" == "${REMOTE_WAN_IP}" ]]; then
        OK_DNS_MATCH=true
    fi
}

# -----------------------------------------------------------------------------
# ROUTER dedup
# -----------------------------------------------------------------------------

ROUTER_REACHABLE=false
ROUTER_STATE_LINE=""
ROUTER_COUNT=0
ROUTER_ALERT_STATE="UP"

# Spoke policy-route visibility (only populated when the feature is on and
# the tunnel ping succeeded). Advisories never change diagnosis.
SPOKE_CHECKED=false
SPOKE_REACHABLE=false
SPOKE_POLICY_LINE=""
SPOKE_POLICY_COUNT=0
SPOKE_POLICY_ALERT=""
SPOKE_WAN_OBSERVED=""
ADVISORIES=""

read_router_state() {
    ROUTER_REACHABLE=false
    ROUTER_STATE_LINE=""
    ROUTER_COUNT=0
    ROUTER_ALERT_STATE="UP"

    local line
    if line="$("${SSH_ROUTER_BIN}" 2>/dev/null)"; then
        ROUTER_REACHABLE=true
        ROUTER_STATE_LINE="${line}"
        ROUTER_COUNT="${line%%:*}"
        ROUTER_ALERT_STATE="${line##*:}"
    fi
}

# -----------------------------------------------------------------------------
# Spoke policy-route visibility (opt-in; does not affect diagnosis)
# -----------------------------------------------------------------------------

append_advisory() {
    if [[ -z "${ADVISORIES}" ]]; then
        ADVISORIES="$1"
    else
        ADVISORIES="${ADVISORIES}
$1"
    fi
}

read_spoke_state() {
    SPOKE_CHECKED=false
    SPOKE_REACHABLE=false
    SPOKE_POLICY_LINE=""
    SPOKE_POLICY_COUNT=0
    SPOKE_POLICY_ALERT=""
    SPOKE_WAN_OBSERVED=""

    if [[ "${SPOKE_POLICY_ENABLED}" != "true" ]]; then
        return 0
    fi
    if [[ "${OK_TUNNEL}" != "true" ]]; then
        return 0
    fi

    SPOKE_CHECKED=true
    local out line1 line2
    if ! out="$("${SSH_SPOKE_BIN}" 2>/dev/null)"; then
        SPOKE_REACHABLE=false
        return 0
    fi
    line1="$(printf '%s\n' "${out}" | sed -n '1p' | tr -d '[:space:]')"
    line2="$(printf '%s\n' "${out}" | sed -n '2p' | tr -d '[:space:]')"
    if [[ ! "${line1}" =~ ^[0-9]+:(UP|DOWN)$ ]] && [[ "${line1}" != "MISSING" ]]; then
        SPOKE_REACHABLE=false
        return 0
    fi
    if [[ ! "${line2}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ "${line2}" != "UNKNOWN" ]]; then
        SPOKE_REACHABLE=false
        return 0
    fi

    SPOKE_REACHABLE=true
    SPOKE_POLICY_LINE="${line1}"
    if [[ "${line1}" != "MISSING" ]]; then
        SPOKE_POLICY_COUNT="${line1%%:*}"
        SPOKE_POLICY_ALERT="${line1##*:}"
    fi
    if [[ "${line2}" != "UNKNOWN" ]]; then
        SPOKE_WAN_OBSERVED="${line2}"
    fi
}

build_advisories() {
    ADVISORIES=""
    if [[ "${SPOKE_POLICY_ENABLED}" != "true" || "${OK_TUNNEL}" != "true" ]]; then
        return 0
    fi
    if [[ "${SPOKE_REACHABLE}" != "true" ]]; then
        append_advisory "SPOKE_UNREACHABLE"
        return 0
    fi
    case "${SPOKE_POLICY_LINE}" in
        MISSING)
            append_advisory "SPOKE_POLICY_MISSING"
            ;;
        *:DOWN)
            append_advisory "SPOKE_POLICY_DOWN"
            ;;
        *:UP)
            if [[ "${SPOKE_POLICY_COUNT}" != "0" ]]; then
                append_advisory "SPOKE_POLICY_DEGRADED"
            fi
            ;;
    esac
    if [[ "${SPOKE_WAN_OBSERVED}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ "${SPOKE_WAN_OBSERVED}" != "${REMOTE_WAN_IP}" ]]; then
            append_advisory "REMOTE_WAN_IP_STALE"
        fi
        if [[ -n "${DNS_RESOLVED}" && "${SPOKE_WAN_OBSERVED}" != "${DNS_RESOLVED}" ]]; then
            append_advisory "REMOTE_DDNS_STALE"
        fi
    fi
}

advisory_phrase() {
    case "$1" in
        SPOKE_UNREACHABLE)    printf '%s' "Spoke unreachable over the tunnel." ;;
        SPOKE_POLICY_MISSING) printf '%s' "${SPOKE_POLICY_LABEL} is not installed on the spoke." ;;
        SPOKE_POLICY_DOWN)    printf '%s' "${SPOKE_POLICY_LABEL} is broken — traffic is not using the tunnel." ;;
        SPOKE_POLICY_DEGRADED) printf '%s' "${SPOKE_POLICY_LABEL} is recovering." ;;
        REMOTE_WAN_IP_STALE)  printf '%s' "Observed WAN ${SPOKE_WAN_OBSERVED} differs from REMOTE_WAN_IP." ;;
        REMOTE_DDNS_STALE)    printf '%s' "Observed WAN ${SPOKE_WAN_OBSERVED} differs from the DDNS record." ;;
        *)                    printf '%s' "$1" ;;
    esac
}

# One banner when the advisory set changes. Sidecar is not alerting state.
notify_advisory_transition() {
    [[ "${SPOKE_CHECKED}" == "true" ]] || return 0
    local cur_file prev_sorted added removed body first extra
    cur_file="$(mktemp -t tunnel-monitor-advisories.XXXXXX)"
    printf '%s\n' "${ADVISORIES}" | sed '/^$/d' | sort -u > "${cur_file}"
    if [[ ! -f "${ADVISORIES_PREV_FILE}" ]]; then
        : > "${ADVISORIES_PREV_FILE}"
    fi
    prev_sorted="$(mktemp -t tunnel-monitor-advisories-prev.XXXXXX)"
    sed '/^$/d' "${ADVISORIES_PREV_FILE}" | sort -u > "${prev_sorted}"
    if ! cmp -s "${cur_file}" "${prev_sorted}"; then
        added="$(comm -13 "${prev_sorted}" "${cur_file}" || true)"
        removed="$(comm -23 "${prev_sorted}" "${cur_file}" || true)"
        if [[ -n "${added}" ]]; then
            first=""
            local code
            while IFS= read -r code; do
                [[ -z "${code}" ]] && continue
                if printf '%s\n' "${added}" | grep -qx "${code}"; then
                    first="${code}"
                    break
                fi
            done <<EOF
${ADVISORIES}
EOF
            [[ -n "${first}" ]] || first="$(printf '%s\n' "${added}" | sed -n '1p')"
            extra="$(printf '%s\n' "${added}" | sed '/^$/d' | wc -l | tr -d ' ')"
            extra=$((extra - 1))
            body="$(advisory_phrase "${first}")"
            if [[ "${extra}" -gt 0 ]]; then
                body="${body} (+${extra} more)"
            fi
            local title="${SPOKE_POLICY_LABEL}"
            case "${first}" in
                REMOTE_*) title="Remote WAN" ;;
            esac
            "${NOTIFY_BIN}" "${title}" "${body}" "${NOTIFY_SOUND_DOWN}" || true
            log_info "advisory banner (new): ${first}"
        elif [[ -n "${removed}" ]]; then
            first="$(printf '%s\n' "${removed}" | sed -n '1p')"
            body="Cleared: $(advisory_phrase "${first}")"
            "${NOTIFY_BIN}" "Advisory cleared" "${body}" "${NOTIFY_SOUND_RECOVERY}" || true
            log_info "advisory banner (cleared): ${first}"
        fi
        cp "${cur_file}" "${ADVISORIES_PREV_FILE}"
        chmod 0644 "${ADVISORIES_PREV_FILE}" 2>/dev/null || true
    fi
    rm -f "${cur_file}" "${prev_sorted}"
}

# -----------------------------------------------------------------------------
# Diagnosis decision tree
# -----------------------------------------------------------------------------

# Apply in order; first match wins. See CURSOR_PROMPT.md for the contract.
diagnose() {
    if [[ "${OK_OUR_INTERNET}" != "true" ]]; then
        printf 'OUR_INTERNET_DOWN'
        return
    fi

    if [[ "${OK_TUNNEL}" == "true" ]]; then
        printf 'HEALTHY'
        return
    fi

    # Tunnel down from here. Classify why.
    if [[ "${ROUTER_REACHABLE}" != "true" ]]; then
        printf 'ROUTER_UNREACHABLE'
        return
    fi

    if [[ "${ROUTER_ALERT_STATE}" == "UP" && "${ROUTER_COUNT}" == "0" ]]; then
        printf 'DISAGREEMENT'
        return
    fi

    if [[ "${OK_DNS_MATCH}" != "true" ]]; then
        printf 'DDNS_DRIFT'
        return
    fi

    if [[ "${OK_REMOTE_WAN}" != "true" ]]; then
        printf 'REMOTE_INTERNET_DOWN'
        return
    fi

    printf 'TUNNEL_DOWN'
}

diagnosis_subject_suffix() {
    case "$1" in
        TUNNEL_DOWN)          printf '%s' 'TUNNEL DOWN' ;;
        DDNS_DRIFT)           printf '%s' 'DDNS DRIFT — fix your DDNS provider record' ;;
        REMOTE_INTERNET_DOWN) printf '%s' 'REMOTE INTERNET DOWN' ;;
        ROUTER_UNREACHABLE)     printf '%s' 'ROUTER UNREACHABLE' ;;
        DISAGREEMENT)         printf '%s' 'DISAGREEMENT (ROUTER says UP)' ;;
        *)                    printf '%s' "$1" ;;
    esac
}

diagnosis_short_line() {
    case "$1" in
        TUNNEL_DOWN)          printf '%s' 'Tunnel ping failing — check the site-to-site VPN on the ROUTER.' ;;
        DDNS_DRIFT)           printf '%s' 'DDNS drift — fix your DDNS provider record.' ;;
        REMOTE_INTERNET_DOWN) printf '%s' 'Remote site internet appears down.' ;;
        ROUTER_UNREACHABLE)     printf '%s' 'ROUTER unreachable — Mac taking over alerting.' ;;
        DISAGREEMENT)         printf '%s' 'Mac sees DOWN but ROUTER says UP — check Mac path.' ;;
        OUR_INTERNET_DOWN)    printf '%s' 'Local internet appears down — no alerting possible.' ;;
        HEALTHY)              printf '%s' 'Tunnel is healthy.' ;;
        *)                    printf '%s' "$1" ;;
    esac
}

# -----------------------------------------------------------------------------
# State file (JSON)
# -----------------------------------------------------------------------------

# Read previous state (defaults if file missing or unparseable).
PREV_FAILURE_COUNT=0
PREV_ALERT_STATE="UP"
PREV_LAST_ALERT_SENT_AT=""
PREV_LAST_RECOVERY_SENT_AT=""

read_prev_state() {
    PREV_FAILURE_COUNT=0
    PREV_ALERT_STATE="UP"
    PREV_LAST_ALERT_SENT_AT=""
    PREV_LAST_RECOVERY_SENT_AT=""

    [[ -f "${STATE_FILE}" ]] || return 0
    if ! jq -e . "${STATE_FILE}" >/dev/null 2>&1; then
        log_warn "state.json unparseable; resetting in-memory state"
        return 0
    fi
    PREV_FAILURE_COUNT="$(jq -r '.failure_count // 0' "${STATE_FILE}")"
    PREV_ALERT_STATE="$(jq -r '.alert_state // "UP"' "${STATE_FILE}")"
    PREV_LAST_ALERT_SENT_AT="$(jq -r '.last_alert_sent_at // empty' "${STATE_FILE}")"
    PREV_LAST_RECOVERY_SENT_AT="$(jq -r '.last_recovery_sent_at // empty' "${STATE_FILE}")"
}

# Atomic write via tmp + mv.
write_state() {
    local failure_count="$1"
    local alert_state="$2"
    local diagnosis="$3"
    local last_alert="$4"
    local last_recovery="$5"
    local checked_at="$6"

    local tmp="${STATE_FILE}.tmp"

    local spoke_enabled_json="false"
    local spoke_reachable_json="null"
    local spoke_state_json="null"
    local spoke_label_json="null"
    local spoke_checked_json="null"
    local observed_json="null"
    local advisories_json="[]"

    if [[ "${SPOKE_POLICY_ENABLED}" == "true" ]]; then
        spoke_enabled_json="true"
        spoke_label_json="$(jq -n --arg s "${SPOKE_POLICY_LABEL}" '$s')"
    fi
    if [[ "${SPOKE_CHECKED}" == "true" ]]; then
        if [[ "${SPOKE_REACHABLE}" == "true" ]]; then
            spoke_reachable_json="true"
        else
            spoke_reachable_json="false"
        fi
        spoke_checked_json="$(jq -n --arg s "${checked_at}" '$s')"
    fi
    if [[ -n "${SPOKE_POLICY_LINE}" ]]; then
        spoke_state_json="$(jq -n --arg s "${SPOKE_POLICY_LINE}" '$s')"
    fi
    if [[ -n "${SPOKE_WAN_OBSERVED}" ]]; then
        observed_json="$(jq -n --arg s "${SPOKE_WAN_OBSERVED}" '$s')"
    fi
    if [[ -n "${ADVISORIES}" ]]; then
        advisories_json="$(printf '%s\n' "${ADVISORIES}" | sed '/^$/d' | jq -R . | jq -s .)"
    fi

    local tunnel_lat="${LATENCY_TUNNEL:-}"
    local rwan_lat="${LATENCY_REMOTE_WAN:-}"
    local our_lat="${LATENCY_OUR_INTERNET:-}"

    if ! jq -n \
        --arg ts "${checked_at}" \
        --arg alert_state "${alert_state}" \
        --argjson failure_count "${failure_count}" \
        --arg tunnel_target "${REMOTE_LAN_IP}" \
        --argjson tunnel_ok "${OK_TUNNEL}" \
        --arg tunnel_lat "${tunnel_lat}" \
        --arg rwan_target "${REMOTE_WAN_IP}" \
        --argjson rwan_ok "${OK_REMOTE_WAN}" \
        --arg rwan_lat "${rwan_lat}" \
        --argjson our_ok "${OK_OUR_INTERNET}" \
        --arg our_lat "${our_lat}" \
        --arg dns_host "${REMOTE_DDNS}" \
        --arg dns_resolved "${DNS_RESOLVED}" \
        --arg dns_expected "${REMOTE_WAN_IP}" \
        --argjson dns_match "${OK_DNS_MATCH}" \
        --argjson router_reachable "${ROUTER_REACHABLE}" \
        --arg router_state "${ROUTER_STATE_LINE}" \
        --arg router_checked "${checked_at}" \
        --arg last_alert "${last_alert}" \
        --arg last_recovery "${last_recovery}" \
        --arg diagnosis "${diagnosis}" \
        --argjson spoke_enabled "${spoke_enabled_json}" \
        --argjson spoke_reachable "${spoke_reachable_json}" \
        --argjson spoke_state "${spoke_state_json}" \
        --argjson spoke_label "${spoke_label_json}" \
        --argjson spoke_checked "${spoke_checked_json}" \
        --argjson remote_wan_observed "${observed_json}" \
        --argjson advisories "${advisories_json}" \
        '{
            timestamp: $ts,
            alert_state: $alert_state,
            failure_count: $failure_count,
            checks: {
                tunnel:       { target: $tunnel_target, ok: $tunnel_ok,  latency_ms: ($tunnel_lat | tonumber? // null) },
                remote_wan:   { target: $rwan_target,   ok: $rwan_ok,    latency_ms: ($rwan_lat   | tonumber? // null) },
                our_internet: { target: "1.1.1.1",      ok: $our_ok,     latency_ms: ($our_lat    | tonumber? // null) },
                dns:          { host: $dns_host, resolved: $dns_resolved, expected: $dns_expected, match: $dns_match }
            },
            router_dedup: {
                reachable: $router_reachable,
                state:     (if $router_state == "" then null else $router_state end),
                checked_at: $router_checked
            },
            last_alert_sent_at:    (if $last_alert    == "" then null else $last_alert    end),
            last_recovery_sent_at: (if $last_recovery == "" then null else $last_recovery end),
            diagnosis: $diagnosis,
            spoke_policy: {
                enabled: $spoke_enabled,
                reachable: $spoke_reachable,
                state: $spoke_state,
                label: $spoke_label,
                checked_at: $spoke_checked
            },
            remote_wan_observed: $remote_wan_observed,
            advisories: $advisories
        }' > "${tmp}" 2>/dev/null; then
        log_error "failed to render state.json"
        rm -f "${tmp}"
        return 1
    fi

    chmod 0644 "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${STATE_FILE}"
}

# -----------------------------------------------------------------------------
# Email body builder
# -----------------------------------------------------------------------------

build_alert_body() {
    local diagnosis="$1"
    local out_file="$2"
    local now_human; now_human="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    local dns_match_str="NO ✗"
    [[ "${OK_DNS_MATCH}" == "true" ]] && dns_match_str="YES ✓"

    local tunnel_str rwan_str our_str
    tunnel_str="$([[ "${OK_TUNNEL}"       == "true" ]] && echo "OK ✓ (${LATENCY_TUNNEL} ms)"      || echo "FAIL ✗")"
    rwan_str="$([[   "${OK_REMOTE_WAN}"   == "true" ]] && echo "OK ✓ (${LATENCY_REMOTE_WAN} ms)"  || echo "FAIL ✗")"
    our_str="$([[    "${OK_OUR_INTERNET}" == "true" ]] && echo "OK ✓ (${LATENCY_OUR_INTERNET} ms)" || echo "FAIL ✗")"

    local router_section
    if [[ "${ROUTER_REACHABLE}" == "true" ]]; then
        router_section="  Reachable:    YES ✓
  State line:   ${ROUTER_STATE_LINE}
  Count:        ${ROUTER_COUNT}
  Alert state:  ${ROUTER_ALERT_STATE}"
    else
        router_section="  Reachable:    NO ✗ — Mac took over alerting"
    fi

    {
        echo "The the remote site site-to-site VPN tunnel has been DOWN for approximately"
        echo "$(( PREV_FAILURE_COUNT * 5 )) minutes (${PREV_FAILURE_COUNT} consecutive failed checks at 5-minute intervals)."
        echo ""
        echo "Diagnosis: $(diagnosis_subject_suffix "${diagnosis}")"
        echo ""
        echo "=============================================="
        echo "TUNNEL DIAGNOSTICS — ${now_human}"
        echo "=============================================="
        echo ""
        echo "[ Tunnel Endpoints ]"
        echo "  Local site (the local site):       Mac (LAN client)"
        echo "  Remote site (the remote site): UDM @ ${REMOTE_LAN_IP} (over tunnel)"
        echo "  Remote public IP expected: ${REMOTE_WAN_IP}"
        echo "  Remote DDNS hostname:      ${REMOTE_DDNS}"
        echo ""
        echo "[ DNS Resolution ]"
        echo "  ${REMOTE_DDNS} currently resolves to: ${DNS_RESOLVED:-<none>}"
        echo "  Expected:                                       ${REMOTE_WAN_IP}"
        echo "  Match:                                          ${dns_match_str}"
        echo ""
        echo "[ Reachability Tests ]"
        echo "  Ping ${REMOTE_LAN_IP} (over tunnel):       ${tunnel_str}"
        echo "  Ping ${REMOTE_WAN_IP} (over internet):     ${rwan_str}"
        echo "  Ping 1.1.1.1 (sanity / our internet):      ${our_str}"
        echo ""
        echo "[ ROUTER Dedup State ]"
        echo "${router_section}"
        echo ""
        echo "[ Mac Monitor State ]"
        echo "  failure_count crossed threshold: ${PREV_FAILURE_COUNT} >= ${FAILURE_THRESHOLD}"
        echo "  state.json: ${STATE_FILE}"
        echo "  log:        ${LOG_FILE}"
        echo ""
        echo "[ Runbook ]"
        case "${diagnosis}" in
            TUNNEL_DOWN)          echo "  SSH the ROUTER (<router_user>@<router_host>), run: journalctl -fu strongswan -n 100" ;;
            DDNS_DRIFT)           echo "  Log into https://my.your-ddns-provider.example.com and update remote.example.com to ${REMOTE_WAN_IP}" ;;
            REMOTE_INTERNET_DOWN) echo "  Nothing to do — call the remote site or wait for their ISP to restore." ;;
            ROUTER_UNREACHABLE)     echo "  Verify the ROUTER is powered/connected. Console at https://<router_host>" ;;
            DISAGREEMENT)         echo "  ROUTER says tunnel is UP but Mac can't reach it. Check Mac routing / restart networking." ;;
        esac
    } > "${out_file}"
}

build_recovery_body() {
    local out_file="$1"
    local now_human; now_human="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    {
        echo "The the remote site site-to-site VPN tunnel has RECOVERED."
        echo ""
        echo "=============================================="
        echo "RECOVERY CONFIRMATION — ${now_human}"
        echo "=============================================="
        echo ""
        echo "[ Reachability Tests (current) ]"
        echo "  Ping ${REMOTE_LAN_IP} (over tunnel):       OK ✓ (${LATENCY_TUNNEL} ms)"
        echo "  Ping ${REMOTE_WAN_IP} (over internet):     $([[ "${OK_REMOTE_WAN}"   == "true" ]] && echo "OK ✓ (${LATENCY_REMOTE_WAN} ms)" || echo "FAIL ✗")"
        echo "  Ping 1.1.1.1 (sanity):                     $([[ "${OK_OUR_INTERNET}" == "true" ]] && echo "OK ✓ (${LATENCY_OUR_INTERNET} ms)" || echo "FAIL ✗")"
        echo ""
        echo "[ DNS Resolution ]"
        echo "  ${REMOTE_DDNS} -> ${DNS_RESOLVED:-<none>} (expected ${REMOTE_WAN_IP})"
        echo ""
        if [[ -n "${PREV_LAST_ALERT_SENT_AT}" ]]; then
            echo "Outage started at: ${PREV_LAST_ALERT_SENT_AT}"
        fi
        echo "Resolved at:       ${now_human}"
    } > "${out_file}"
}

# -----------------------------------------------------------------------------
# Alert dispatch
# -----------------------------------------------------------------------------

send_alert_email() {
    local diagnosis="$1"
    local body_file
    body_file="$(mktemp -t tunnel-monitor-alert-body.XXXXXX)"
    build_alert_body "${diagnosis}" "${body_file}"

    local subject="⚠ the remote site Tunnel DOWN — $(diagnosis_subject_suffix "${diagnosis}")"
    if "${SEND_EMAIL_BIN}" "${subject}" "${body_file}"; then
        log_info "alert email sent: ${subject}"
    else
        log_error "alert email failed: ${subject}"
    fi
    rm -f "${body_file}"
}

send_recovery_email() {
    local body_file
    body_file="$(mktemp -t tunnel-monitor-recovery-body.XXXXXX)"
    build_recovery_body "${body_file}"

    local subject="✓ the remote site Tunnel RECOVERED"
    if "${SEND_EMAIL_BIN}" "${subject}" "${body_file}"; then
        log_info "recovery email sent: ${subject}"
    else
        log_error "recovery email failed: ${subject}"
    fi
    rm -f "${body_file}"
}

send_down_banner() {
    local diagnosis="$1"
    local body
    body="$(diagnosis_short_line "${diagnosis}")"
    "${NOTIFY_BIN}" "Tunnel DOWN" "${body}" "${NOTIFY_SOUND_DOWN}" || true
}

send_recovery_banner() {
    "${NOTIFY_BIN}" "Tunnel RECOVERED" "Tunnel back up — pings flowing." "${NOTIFY_SOUND_RECOVERY}" || true
}

# -----------------------------------------------------------------------------
# Main check (the launchd entrypoint)
# -----------------------------------------------------------------------------

cmd_check() {
    rotate_log_if_needed
    load_config

    if ! ensure_dependencies; then
        log_error "missing dependencies — aborting check"
        exit 0
    fi

    local now_iso; now_iso="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

    read_prev_state
    run_health_checks
    read_router_state
    read_spoke_state
    build_advisories

    local diagnosis; diagnosis="$(diagnose)"

    log_info "diagnosis=${diagnosis} tunnel=${OK_TUNNEL} rwan=${OK_REMOTE_WAN} our=${OK_OUR_INTERNET} dns=${OK_DNS_MATCH} router_reachable=${ROUTER_REACHABLE} router_state=${ROUTER_STATE_LINE:-<n/a>} prev=${PREV_FAILURE_COUNT}:${PREV_ALERT_STATE}"

    local new_failure_count="${PREV_FAILURE_COUNT}"
    local new_alert_state="${PREV_ALERT_STATE}"
    local last_alert="${PREV_LAST_ALERT_SENT_AT}"
    local last_recovery="${PREV_LAST_RECOVERY_SENT_AT}"

    case "${diagnosis}" in
        OUR_INTERNET_DOWN)
            # We are offline — cannot trust the test. Hold state, log, exit clean.
            log_warn "our internet is down; holding state at ${PREV_FAILURE_COUNT}:${PREV_ALERT_STATE}"
            notify_advisory_transition || true
            write_state "${new_failure_count}" "${new_alert_state}" "${diagnosis}" \
                "${last_alert}" "${last_recovery}" "${now_iso}" || true
            exit 0
            ;;

        HEALTHY)
            new_failure_count=0
            if [[ "${PREV_ALERT_STATE}" == "DOWN" ]]; then
                log_info "tunnel recovered — sending recovery email + banner"
                send_recovery_email
                send_recovery_banner
                last_recovery="${now_iso}"
            fi
            new_alert_state="UP"
            ;;

        *)
            # All non-healthy diagnoses count as failures.
            new_failure_count=$(( PREV_FAILURE_COUNT + 1 ))

            if (( new_failure_count >= FAILURE_THRESHOLD )) && [[ "${PREV_ALERT_STATE}" != "DOWN" ]]; then
                log_warn "failure threshold crossed (${new_failure_count}/${FAILURE_THRESHOLD}) — diagnosis=${diagnosis}"

                local email_skip=false
                if [[ "${ROUTER_REACHABLE}" == "true" && "${ROUTER_ALERT_STATE}" == "DOWN" ]]; then
                    email_skip=true
                    log_info "suppressing duplicate email — ROUTER already alerted (${ROUTER_STATE_LINE})"
                fi

                if [[ "${email_skip}" == "false" ]]; then
                    send_alert_email "${diagnosis}"
                    last_alert="${now_iso}"
                fi
                # Always banner, regardless of dedup.
                send_down_banner "${diagnosis}"
                new_alert_state="DOWN"
            elif [[ "${PREV_ALERT_STATE}" == "DOWN" ]]; then
                log_info "still DOWN (failure_count=${new_failure_count}) — diagnosis=${diagnosis}, no re-alert"
            else
                log_info "failure ${new_failure_count}/${FAILURE_THRESHOLD} — counting, no alert yet"
            fi
            ;;
    esac

    write_state "${new_failure_count}" "${new_alert_state}" "${diagnosis}" \
        "${last_alert}" "${last_recovery}" "${now_iso}" || true

    # Advisories never email. One banner per set transition.
    notify_advisory_transition || true

    exit 0
}

# -----------------------------------------------------------------------------
# Diagnose-only (no state mutation)
# -----------------------------------------------------------------------------

cmd_diagnose() {
    load_config
    ensure_dependencies || true
    run_health_checks
    read_router_state
    read_spoke_state
    build_advisories
    local diagnosis; diagnosis="$(diagnose)"
    cat <<EOF
Diagnosis:        ${diagnosis}
Tunnel ping:      ok=${OK_TUNNEL}       latency=${LATENCY_TUNNEL:-n/a} ms
Remote WAN ping:  ok=${OK_REMOTE_WAN}   latency=${LATENCY_REMOTE_WAN:-n/a} ms
Our internet:     ok=${OK_OUR_INTERNET} latency=${LATENCY_OUR_INTERNET:-n/a} ms
DNS:              host=${REMOTE_DDNS} resolved=${DNS_RESOLVED:-<none>} expected=${REMOTE_WAN_IP} match=${OK_DNS_MATCH}
ROUTER:             reachable=${ROUTER_REACHABLE} state=${ROUTER_STATE_LINE:-<n/a>}
EOF
    if [[ "${SPOKE_POLICY_ENABLED}" == "true" ]]; then
        printf 'Spoke policy:     reachable=%s state=%s observed=%s\n' \
            "${SPOKE_REACHABLE}" "${SPOKE_POLICY_LINE:-<n/a>}" "${SPOKE_WAN_OBSERVED:-<n/a>}"
        printf 'Advisories:       %s\n' "${ADVISORIES:-<none>}"
    fi
    exit 0
}

cmd_notify_test() {
    load_config
    "${NOTIFY_BIN}" "Tunnel TEST" "Synthetic test notification from monitor.sh" "${NOTIFY_SOUND_DOWN}"
    exit 0
}

cmd_email_test() {
    load_config
    local body_file; body_file="$(mktemp -t tunnel-monitor-test.XXXXXX)"
    {
        echo "This is a synthetic test from the Mac tunnel monitor."
        echo ""
        echo "Sent at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Host:    $(hostname -s)"
        echo "Script:  ${BASH_SOURCE[0]}"
        echo ""
        echo "If you received this, SMTP plumbing is working."
    } > "${body_file}"
    if "${SEND_EMAIL_BIN}" "TEST — tunnel monitor plumbing check" "${body_file}"; then
        echo "Test email submitted successfully."
    else
        echo "Test email submission FAILED — check ${LOG_FILE}." >&2
    fi
    rm -f "${body_file}"
    exit 0
}

cmd_ssh_test() {
    load_config
    if line="$("${SSH_ROUTER_BIN}")"; then
        echo "OK: ROUTER state line = ${line}"
    else
        echo "FAIL: ssh-router-state.sh exited non-zero (see stderr)" >&2
        exit 1
    fi
    exit 0
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------

case "${1:-check}" in
    --help|-h|help) show_help; exit 0 ;;
    check)          cmd_check ;;
    diagnose)       cmd_diagnose ;;
    notify-test)    cmd_notify_test ;;
    email-test)     cmd_email_test ;;
    ssh-test)       cmd_ssh_test ;;
    *)
        echo "ERROR: unknown subcommand: $1" >&2
        show_help >&2
        exit 1
        ;;
esac
