#!/bin/bash
# =============================================================================
# Site-to-site Tunnel Health Monitor
# =============================================================================
# Runs every 5 minutes via systemd timer. Tracks consecutive failures.
# After 3 consecutive failures (~15 min outage), sends an email alert.
# When tunnel recovers after being marked DOWN, sends a recovery alert.
#
# =============================================================================

set -u

SCRIPT_DIR="/data/tunnel-monitor"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
STATE_FILE="${SCRIPT_DIR}/state"
LOG_TAG="tunnel-monitor"

# ---- Load config ------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t "$LOG_TAG" -p user.err "Config file missing: $CONFIG_FILE"
    echo "ERROR: Config file missing: $CONFIG_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ---- Defaults (override in config.env) --------------------------------------
REMOTE_LAN_IP="${REMOTE_LAN_IP:-192.0.2.1}"
REMOTE_WAN_IP="${REMOTE_WAN_IP:-198.51.100.1}"
REMOTE_DDNS="${REMOTE_DDNS:-remote.example.com}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
PING_COUNT="${PING_COUNT:-3}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"
# Optional prefix prepended to every email subject (e.g. "[ROUTER]"). Leave
# empty to send unprefixed subjects (the original behaviour).
SUBJECT_PREFIX="${SUBJECT_PREFIX:-}"
SEND_EMAIL_SCRIPT="${SCRIPT_DIR}/send-email.sh"

# ---- Helpers ----------------------------------------------------------------
log() {
    local level="$1"; shift
    logger -t "$LOG_TAG" -p "user.${level}" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

read_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "0:UP"
    fi
}

write_state() {
    echo "$1" > "$STATE_FILE"
}

# Ping a host. Returns 0 on success, 1 on failure.
check_ping() {
    local target="$1"
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$target" >/dev/null 2>&1
}

# Resolve a hostname to its A record. Echoes the IP or empty.
resolve_ddns() {
    dig +short +time=3 +tries=1 "$REMOTE_DDNS" @1.1.1.1 2>/dev/null | head -1
}

# Check IPsec tunnel status via ipsec command. Returns 0 if ESTABLISHED.
check_ipsec() {
    ipsec statusall 2>/dev/null | grep -q "ESTABLISHED"
}

# Build a rich diagnostic block for the alert email.
build_diagnostics() {
    local resolved_ip
    resolved_ip=$(resolve_ddns)
    cat <<EOF
==============================================
TUNNEL DIAGNOSTICS — $(date '+%Y-%m-%d %H:%M:%S %Z')
==============================================

[ Tunnel Endpoints ]
  Local site:                UniFi gateway @ $(hostname -I | awk '{print $1}')
  Remote site:               remote LAN gateway @ ${REMOTE_LAN_IP} (over tunnel)
  Remote public IP expected: ${REMOTE_WAN_IP}
  Remote DDNS hostname:      ${REMOTE_DDNS}

[ DNS Resolution ]
  ${REMOTE_DDNS} currently resolves to: ${resolved_ip:-FAILED}
  Expected:                              ${REMOTE_WAN_IP}
  Match:                                 $([ "$resolved_ip" = "$REMOTE_WAN_IP" ] && echo "YES ✓" || echo "NO ✗ — UPDATE YOUR DDNS RECORD")

[ Reachability Tests ]
  Ping ${REMOTE_LAN_IP} (over tunnel):       $(check_ping "$REMOTE_LAN_IP" && echo "OK ✓" || echo "FAIL ✗")
  Ping ${REMOTE_WAN_IP} (over internet):     $(check_ping "$REMOTE_WAN_IP" && echo "OK ✓" || echo "FAIL ✗")
  Ping 1.1.1.1 (sanity / our internet):      $(check_ping "1.1.1.1" && echo "OK ✓" || echo "FAIL ✗")

[ IPsec Status ]
$(ipsec statusall 2>/dev/null | grep -E "(ESTABLISHED|CONNECTING|INSTALLED|Security Associations|^[a-f0-9]{20,}:)" | head -20 || echo "  ipsec statusall returned no relevant output")

[ Recent strongSwan Log (last 15 lines) ]
$(journalctl --no-pager -n 15 | grep -i charon || echo "  No recent charon log entries")

==============================================
EOF
}

# ---- Main check -------------------------------------------------------------
STATE_RAW=$(read_state)
FAIL_COUNT="${STATE_RAW%%:*}"
ALERT_STATE="${STATE_RAW##*:}"

# Run checks. Tunnel is "healthy" if we can ping the remote LAN IP over it.
if check_ping "$REMOTE_LAN_IP"; then
    TUNNEL_OK=1
else
    TUNNEL_OK=0
fi

# Also check if the remote site's internet is even up (so we can
# differentiate "the tunnel is broken" from "the remote site is offline").
if check_ping "$REMOTE_WAN_IP"; then
    REMOTE_INTERNET_OK=1
else
    REMOTE_INTERNET_OK=0
fi

# ---- State machine ----------------------------------------------------------
if [[ $TUNNEL_OK -eq 1 ]]; then
    # Tunnel is up
    if [[ "$ALERT_STATE" == "DOWN" ]]; then
        # Recovery!
        log info "Tunnel RECOVERED after being down. Sending recovery alert."
        SUBJECT="${SUBJECT_PREFIX:+${SUBJECT_PREFIX} }✓ Site-to-site Tunnel RECOVERED"
        BODY="$(printf 'The site-to-site VPN tunnel has recovered and is now UP.\n\n%s' "$(build_diagnostics)")"
        "$SEND_EMAIL_SCRIPT" "$SUBJECT" "$BODY" || log err "Failed to send recovery email"
        write_state "0:UP"
    else
        # Normal — tunnel up, still up. Reset failure counter quietly.
        if [[ "$FAIL_COUNT" -ne 0 ]]; then
            log info "Tunnel healthy. Resetting failure counter (was ${FAIL_COUNT})."
        fi
        write_state "0:UP"
    fi
else
    # Tunnel is down
    NEW_FAIL_COUNT=$((FAIL_COUNT + 1))

    if [[ $NEW_FAIL_COUNT -ge $FAILURE_THRESHOLD && "$ALERT_STATE" == "UP" ]]; then
        # Threshold crossed — fire the alert
        log warning "Tunnel DOWN — failure ${NEW_FAIL_COUNT}/${FAILURE_THRESHOLD}. Sending alert."

        # Try to give a meaningful diagnosis in the subject line
        if [[ $REMOTE_INTERNET_OK -eq 0 ]]; then
            DIAGNOSIS="REMOTE INTERNET DOWN"
        else
            RESOLVED=$(resolve_ddns)
            if [[ "$RESOLVED" != "$REMOTE_WAN_IP" ]]; then
                DIAGNOSIS="DDNS DRIFT — fix your DDNS provider record"
            else
                DIAGNOSIS="TUNNEL DOWN"
            fi
        fi

        SUBJECT="${SUBJECT_PREFIX:+${SUBJECT_PREFIX} }⚠ Site-to-site Tunnel DOWN — ${DIAGNOSIS}"
        BODY="$(printf 'The site-to-site VPN tunnel has been down for approximately %d minutes.\n\nDiagnosis: %s\n\n%s' \
            "$((NEW_FAIL_COUNT * 5))" "$DIAGNOSIS" "$(build_diagnostics)")"
        "$SEND_EMAIL_SCRIPT" "$SUBJECT" "$BODY" || log err "Failed to send DOWN alert email"
        write_state "${NEW_FAIL_COUNT}:DOWN"
    elif [[ "$ALERT_STATE" == "DOWN" ]]; then
        # Still down, alert already sent — don't spam
        log warning "Tunnel still DOWN (failure ${NEW_FAIL_COUNT}). Alert already sent; not re-alerting."
        write_state "${NEW_FAIL_COUNT}:DOWN"
    else
        # Failing but threshold not yet crossed
        log notice "Tunnel ping failed (${NEW_FAIL_COUNT}/${FAILURE_THRESHOLD}). Not yet alerting."
        write_state "${NEW_FAIL_COUNT}:UP"
    fi
fi
