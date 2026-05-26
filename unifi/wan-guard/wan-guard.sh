#!/bin/bash
# =============================================================================
# wan-guard.sh — WAN2 DDNS Protection & CGNAT Failover Guard
# Installs to: /data/wan-guard/wan-guard.sh  (survives firmware updates)
# Companion to: /data/tunnel-monitor/
#
# Problem solved:
#   Dual-WAN hubs often have a CGNAT backup WAN (192.168.x / 100.64.x) and a
#   primary public WAN. If a DDNS client pushes the backup's private address
#   to the hub hostname, the remote site resolves an unroutable target and the
#   site-to-site VPN (OpenVPN or IPsec) cannot establish or flaps until DNS
#   is corrected.
#
# What this script does:
#   1. Reads the current primary public WAN IP from WAN_GUARD_INTERFACE
#   2. Validates it is a public/routable address (not RFC1918 / CGNAT)
#   3. Compares against what No-IP currently has for the hostname
#   4. Updates No-IP only if the IP is public AND has changed
#   5. Sends email alerts on: CGNAT detected, IP change, update failure
#   6. Writes a state file readable by tunnel-monitor for correlation
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Load config (shared with tunnel-monitor)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/config.env" && -f /data/wan-guard/config.env ]]; then
    SCRIPT_DIR="/data/wan-guard"
fi
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/wan-guard.state}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/wan-guard.log}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# tunnel-monitor config.env uses ALERT_TO / SMTP_PASSWORD / ALERT_FROM
ALERT_EMAIL="${ALERT_EMAIL:-${ALERT_TO:-}}"
SMTP_PASS="${SMTP_PASS:-${SMTP_PASSWORD:-}}"
ALERT_FROM="${ALERT_FROM:-${SMTP_USER:-}}"
SMTP_PORT="${SMTP_PORT:-587}"

# ---------------------------------------------------------------------------
# Required config keys (validated below)
# ---------------------------------------------------------------------------
# WAN_GUARD_INTERFACE      — interface for primary public WAN (verify with ip -4 addr)
# WAN_GUARD_HOSTNAME       — DDNS hostname remote site dials (REPLACE_WITH_HUB_DDNS_HOSTNAME)
# WAN_GUARD_NOIP_USER      — No-IP account username
# WAN_GUARD_NOIP_PASS      — No-IP account password (or app token)
# SMTP_* / ALERT_EMAIL (or ALERT_TO) — shared with /data/tunnel-monitor/config.env

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
WAN_GUARD_INTERFACE="${WAN_GUARD_INTERFACE:-}"
WAN_GUARD_HOSTNAME="${WAN_GUARD_HOSTNAME:-}"
WAN_GUARD_DRY_RUN="${WAN_GUARD_DRY_RUN:-false}"
WAN_GUARD_LOG_MAX_LINES="${WAN_GUARD_LOG_MAX_LINES:-2000}"
NOIP_UPDATE_URL="https://dynupdate.no-ip.com/nic/update"
NOIP_CHECK_URL="https://api.ipify.org"          # fallback public IP check
CURL_TIMEOUT=10
CURL_RETRIES=3

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }

rotate_log() {
    local lines
    lines="$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)"
    if (( lines > WAN_GUARD_LOG_MAX_LINES )); then
        local tmp="${LOG_FILE}.tmp"
        tail -n "${WAN_GUARD_LOG_MAX_LINES}" "${LOG_FILE}" > "${tmp}"
        mv "${tmp}" "${LOG_FILE}"
        log_info "Log rotated at ${lines} lines"
    fi
}

# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------
validate_config() {
    local missing=()
    [[ -z "${WAN_GUARD_INTERFACE:-}"  ]] && missing+=("WAN_GUARD_INTERFACE")
    [[ -z "${WAN_GUARD_HOSTNAME:-}"   ]] && missing+=("WAN_GUARD_HOSTNAME")
    [[ -z "${WAN_GUARD_NOIP_USER:-}" ]] && missing+=("WAN_GUARD_NOIP_USER")
    [[ -z "${WAN_GUARD_NOIP_PASS:-}" ]] && missing+=("WAN_GUARD_NOIP_PASS")
    [[ -z "${ALERT_EMAIL:-}"          ]] && missing+=("ALERT_EMAIL|ALERT_TO")
    [[ -z "${SMTP_SERVER:-}"          ]] && missing+=("SMTP_SERVER")

    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required config keys: ${missing[*]}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# RFC1918 / CGNAT / reserved IP detection
# Returns 0 if the IP is PRIVATE/unroutable, 1 if it is PUBLIC
# ---------------------------------------------------------------------------
is_private_ip() {
    local ip="$1"

    # Validate format first
    if ! [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log_warn "is_private_ip: invalid IP format: '${ip}'"
        return 0   # treat as private/invalid to be safe
    fi

    IFS='.' read -r a b c d <<< "${ip}"

    # RFC1918 private ranges
    [[ "${a}" -eq 10 ]] && return 0
    [[ "${a}" -eq 172 && "${b}" -ge 16 && "${b}" -le 31 ]] && return 0
    [[ "${a}" -eq 192 && "${b}" -eq 168 ]] && return 0

    # CGNAT (RFC6598) — 100.64.0.0/10 — carrier-grade NAT
    [[ "${a}" -eq 100 && "${b}" -ge 64 && "${b}" -le 127 ]] && return 0

    # Loopback
    [[ "${a}" -eq 127 ]] && return 0

    # Link-local
    [[ "${a}" -eq 169 && "${b}" -eq 254 ]] && return 0

    # Multicast / reserved
    [[ "${a}" -ge 224 ]] && return 0

    return 1   # public/routable
}

# ---------------------------------------------------------------------------
# Get current IP from WAN interface
# ---------------------------------------------------------------------------
get_wan_ip() {
    local iface="$1"
    local ip

    # Primary: read from interface
    ip="$(ip -4 addr show "${iface}" 2>/dev/null \
          | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
          | head -1 || true)"

    if [[ -n "${ip}" ]]; then
        echo "${ip}"
        return 0
    fi

    log_warn "Could not read IP from interface ${iface}"
    return 1
}

# ---------------------------------------------------------------------------
# Query what No-IP currently has for the hostname
# Uses DNS resolution — not the No-IP API (no auth required for reads)
# ---------------------------------------------------------------------------
get_noip_current_ip() {
    local hostname="$1"
    local resolved

    resolved="$(dig +short "${hostname}" A 2>/dev/null | grep -oP '^\d+(\.\d+){3}$' | head -1 || true)"

    # Fallback to nslookup if dig not available
    if [[ -z "${resolved}" ]]; then
        resolved="$(nslookup "${hostname}" 2>/dev/null \
                    | awk '/^Address: / && !/^Address: 192\.168/ {print $2; exit}' || true)"
    fi

    echo "${resolved}"
}

# ---------------------------------------------------------------------------
# Push update to No-IP
# Returns 0 on success, 1 on failure
# Handles No-IP response codes per:
# https://www.noip.com/integrate/response
# ---------------------------------------------------------------------------
update_noip() {
    local hostname="$1"
    local new_ip="$2"
    local response
    local exit_code=0

    log_info "Updating No-IP: ${hostname} → ${new_ip}"

    if [[ "${WAN_GUARD_DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would update ${hostname} to ${new_ip}"
        return 0
    fi

    response="$(curl \
        --silent \
        --max-time "${CURL_TIMEOUT}" \
        --retry "${CURL_RETRIES}" \
        --retry-delay 5 \
        --user-agent "wan-guard/1.0 roto1231@mac.com" \
        --user "${WAN_GUARD_NOIP_USER}:${WAN_GUARD_NOIP_PASS}" \
        "${NOIP_UPDATE_URL}?hostname=${hostname}&myip=${new_ip}" \
        2>&1)" || exit_code=$?

    if (( exit_code != 0 )); then
        log_error "No-IP curl failed (exit ${exit_code}): ${response}"
        return 1
    fi

    # Parse No-IP response codes
    case "${response}" in
        "good "*)
            log_info "No-IP update SUCCESS: ${response}"
            return 0
            ;;
        "nochg "*)
            log_info "No-IP: no change needed (already ${new_ip}): ${response}"
            return 0
            ;;
        "nohost")
            log_error "No-IP: hostname not found — check account: ${hostname}"
            return 1
            ;;
        "badauth")
            log_error "No-IP: authentication failed — check credentials"
            return 1
            ;;
        "abuse")
            log_error "No-IP: account flagged for abuse — update manually"
            return 1
            ;;
        "911")
            log_error "No-IP: service outage (911 response) — retry later"
            return 1
            ;;
        *)
            log_warn "No-IP: unexpected response: '${response}'"
            # Don't treat unknown responses as fatal
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Email alert (reuses tunnel-monitor SMTP config)
# ---------------------------------------------------------------------------
send_alert() {
    local subject="$1"
    local body="$2"
    local tmpfile

    if [[ -z "${SMTP_SERVER:-}" || -z "${ALERT_EMAIL:-}" || -z "${SMTP_PASS:-}" ]]; then
        log_warn "Email not configured — skipping alert: ${subject}"
        return 0
    fi

    log_info "Sending alert: ${subject}"

    tmpfile="$(mktemp)"
    cat > "${tmpfile}" <<EOF
From: ${ALERT_FROM}
To: ${ALERT_EMAIL}
Subject: ${subject}
Date: $(date -R)
Content-Type: text/plain; charset=UTF-8

${body}

---
Host: $(hostname)
Time: $(date)
Interface: ${WAN_GUARD_INTERFACE}
Hostname: ${WAN_GUARD_HOSTNAME}
EOF

    curl --silent --show-error --ssl-reqd \
         --max-time 30 \
         --url "smtp://${SMTP_SERVER}:${SMTP_PORT}" \
         --user "${SMTP_USER}:${SMTP_PASS}" \
         --mail-from "${ALERT_FROM}" \
         --mail-rcpt "${ALERT_EMAIL}" \
         --upload-file "${tmpfile}" \
         2>/dev/null || log_warn "Email send failed"
    rm -f "${tmpfile}"
}

# ---------------------------------------------------------------------------
# Read / write persistent state
# State file format: KEY=VALUE (one per line)
# ---------------------------------------------------------------------------
read_state() {
    local key="$1"
    if [[ -f "${STATE_FILE}" ]]; then
        grep -E "^${key}=" "${STATE_FILE}" | cut -d= -f2- | tail -1 || true
    fi
}

write_state() {
    local key="$1"
    local value="$2"
    local tmp="${STATE_FILE}.tmp"

    # Preserve all other keys, replace/add this one
    if [[ -f "${STATE_FILE}" ]]; then
        grep -v "^${key}=" "${STATE_FILE}" > "${tmp}" || true
    else
        touch "${tmp}"
    fi
    echo "${key}=${value}" >> "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Core check logic
# ---------------------------------------------------------------------------
run_check() {
    local current_wan_ip
    local current_noip_ip
    local last_alerted_cgnat
    local last_ip

    # Get current WAN2 IP
    if ! current_wan_ip="$(get_wan_ip "${WAN_GUARD_INTERFACE}")"; then
        log_error "Cannot read IP from ${WAN_GUARD_INTERFACE} — interface down?"
        send_alert \
            "⚠ WAN Guard: ${WAN_GUARD_INTERFACE} interface unreadable" \
            "wan-guard cannot read an IP from interface ${WAN_GUARD_INTERFACE}.\n\nThis may indicate the primary public WAN is down or the interface assignment changed."
        write_state "last_check_status" "interface_error"
        return 1
    fi

    log_info "WAN (${WAN_GUARD_INTERFACE}) current IP: ${current_wan_ip}"
    write_state "wan_ip" "${current_wan_ip}"
    write_state "last_check_ts" "$(date '+%Y-%m-%d %H:%M:%S')"

    # --- CGNAT / private IP guard ---
    if is_private_ip "${current_wan_ip}"; then
        last_alerted_cgnat="$(read_state "last_cgnat_alert_ip")"

        log_warn "CGNAT/private IP detected on ${WAN_GUARD_INTERFACE}: ${current_wan_ip} — DDNS update BLOCKED"
        write_state "last_check_status" "cgnat_blocked"

        # Only alert once per unique private IP (avoid spam on every 5-min check)
        if [[ "${last_alerted_cgnat}" != "${current_wan_ip}" ]]; then
            send_alert \
                "🚨 WAN Guard: CGNAT/private IP on primary WAN — DDNS blocked" \
"CGNAT/private IP detected on ${WAN_GUARD_INTERFACE}: ${current_wan_ip}

This is unexpected for the primary public WAN. Possible causes:
  - Primary WAN is down; failover assigned a CGNAT backup address
  - Interface assignment changed in UniFi
  - A firmware update reassigned WAN interfaces

DDNS update for ${WAN_GUARD_HOSTNAME} has been BLOCKED to prevent
${WAN_GUARD_HOSTNAME} from resolving to an unroutable address.

Action required:
  1. Verify ${WAN_GUARD_INTERFACE} is still the primary public WAN interface
  2. Check UniFi → Internet → interface assignments
  3. Current No-IP record is preserved; verify it still has the last good IP
  4. Once public IP is restored, wan-guard will auto-update DDNS"
            write_state "last_cgnat_alert_ip" "${current_wan_ip}"
        fi

        return 0   # Not an error — we intentionally did nothing
    fi

    # --- Public IP confirmed — check against No-IP ---
    current_noip_ip="$(get_noip_current_ip "${WAN_GUARD_HOSTNAME}")"
    last_ip="$(read_state "last_good_ip")"

    log_info "No-IP current record: ${current_noip_ip:-<unresolvable>}"
    write_state "noip_ip" "${current_noip_ip}"

    if [[ "${current_wan_ip}" == "${current_noip_ip}" ]]; then
        log_info "DDNS in sync: ${WAN_GUARD_HOSTNAME} = ${current_wan_ip} ✓"
        write_state "last_check_status" "in_sync"
        write_state "last_good_ip" "${current_wan_ip}"
        write_state "last_cgnat_alert_ip" ""   # clear CGNAT alert state
        return 0
    fi

    # --- IP mismatch — update needed ---
    log_warn "DDNS mismatch: No-IP has '${current_noip_ip}', WAN is '${current_wan_ip}'"

    if update_noip "${WAN_GUARD_HOSTNAME}" "${current_wan_ip}"; then
        write_state "last_good_ip" "${current_wan_ip}"
        write_state "last_check_status" "updated"
        write_state "last_update_ts" "$(date '+%Y-%m-%d %H:%M:%S')"

        local change_type="IP change"
        if is_private_ip "${current_noip_ip:-0.0.0.0}"; then
            change_type="CGNAT RECOVERY"
        fi

        send_alert \
            "✅ WAN Guard: ${change_type} — ${WAN_GUARD_HOSTNAME} updated" \
"DDNS record updated successfully.

Hostname : ${WAN_GUARD_HOSTNAME}
Old IP   : ${current_noip_ip:-unknown}
New IP   : ${current_wan_ip}
Change   : ${change_type}

The remote gateway will pick up the new IP on the next OpenVPN reconnect.
If the spoke tunnel does not show Connected within 5 minutes, edit and
re-save the tunnel on either gateway to force a hostname re-resolve."
    else
        write_state "last_check_status" "update_failed"
        send_alert \
            "❌ WAN Guard: DDNS update FAILED for ${WAN_GUARD_HOSTNAME}" \
"Failed to update No-IP for ${WAN_GUARD_HOSTNAME}.

Current WAN IP  : ${current_wan_ip}
No-IP record    : ${current_noip_ip:-unknown}

Manual fix required:
  1. Log into noip.com → DNS Records
  2. Update ${WAN_GUARD_HOSTNAME} → ${current_wan_ip}
  3. Check wan-guard log: tail ${LOG_FILE}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------
cmd_check() {
    rotate_log
    log_info "=== wan-guard check starting ==="
    validate_config
    run_check
    local rc=$?
    log_info "=== wan-guard check complete (rc=${rc}) ==="
    return ${rc}
}

cmd_status() {
    echo "=== WAN Guard Status ==="
    echo "Config file  : ${CONFIG_FILE}"
    echo "State file   : ${STATE_FILE}"
    echo "Log file     : ${LOG_FILE}"
    echo ""

    if [[ -f "${STATE_FILE}" ]]; then
        echo "--- State ---"
        cat "${STATE_FILE}"
    else
        echo "(no state file yet — run wan-guard check first)"
    fi

    echo ""
    echo "--- DNS Check ---"
    local resolved
    resolved="$(get_noip_current_ip "${WAN_GUARD_HOSTNAME}" 2>/dev/null || echo "resolution failed")"
    echo "${WAN_GUARD_HOSTNAME} → ${resolved}"

    echo ""
    echo "--- Interface Check ---"
    local wan_ip
    wan_ip="$(get_wan_ip "${WAN_GUARD_INTERFACE}" 2>/dev/null || echo "unreadable")"
    echo "${WAN_GUARD_INTERFACE} current IP → ${wan_ip}"

    if is_private_ip "${wan_ip}"; then
        echo "⚠  WARNING: ${WAN_GUARD_INTERFACE} has a PRIVATE/CGNAT IP — DDNS updates blocked"
    else
        echo "✓  Public IP confirmed"
    fi
}

cmd_test_email() {
    validate_config
    send_alert \
        "✅ WAN Guard: test email from $(hostname)" \
        "This is a test email from wan-guard on $(hostname).

Config:
  Interface : ${WAN_GUARD_INTERFACE}
  Hostname  : ${WAN_GUARD_HOSTNAME}
  Log       : ${LOG_FILE}

If you received this, email alerting is working correctly."
    echo "Test email sent to ${ALERT_EMAIL}"
}

cmd_force_update() {
    validate_config
    local wan_ip
    wan_ip="$(get_wan_ip "${WAN_GUARD_INTERFACE}")"

    if is_private_ip "${wan_ip}"; then
        echo "ERROR: ${WAN_GUARD_INTERFACE} has private IP ${wan_ip} — refusing force update"
        exit 1
    fi

    echo "Force updating ${WAN_GUARD_HOSTNAME} → ${wan_ip}"
    WAN_GUARD_DRY_RUN=false update_noip "${WAN_GUARD_HOSTNAME}" "${wan_ip}"
}

cmd_tail() {
    tail -f "${LOG_FILE}"
}

cmd_history() {
    local n="${1:-50}"
    tail -n "${n}" "${LOG_FILE}"
}

cmd_help() {
    cat <<'EOF'
wan-guard — WAN2 DDNS protection and CGNAT guard

Usage:
  wan-guard check          Run a DDNS check (called by systemd timer)
  wan-guard status         Show current state, DNS resolution, and interface IP
  wan-guard force-update   Force a No-IP update with current WAN2 IP
  wan-guard test-email     Send a test alert email
  wan-guard tail           Follow the log in real time
  wan-guard history [N]    Show last N log lines (default 50)
  wan-guard help           Show this message

Config: /data/wan-guard/config.env
State:  /data/wan-guard/wan-guard.state
Log:    /data/wan-guard/wan-guard.log
EOF
}

# ---------------------------------------------------------------------------
# Entry point — skipped when sourced for testing (WAN_GUARD_TEST_MODE=1)
# ---------------------------------------------------------------------------
[[ "${WAN_GUARD_TEST_MODE:-0}" == "1" ]] && return 0 2>/dev/null || true

case "${1:-check}" in
    check)         cmd_check        ;;
    status)        cmd_status       ;;
    force-update)  cmd_force_update ;;
    test-email)    cmd_test_email   ;;
    tail)          cmd_tail         ;;
    history)       cmd_history "${2:-50}" ;;
    help|--help|-h) cmd_help       ;;
    *)
        echo "Unknown command: $1" >&2
        cmd_help >&2
        exit 1
        ;;
esac
