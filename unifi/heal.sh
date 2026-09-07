#!/bin/bash
# =============================================================================
# heal.sh — bounded IPsec recovery for the UniFi gateway tunnel monitor
# =============================================================================
# Invoked by monitor.sh, or manually:
#   heal.sh <diagnosis>              attempt recovery
#   heal.sh --dry-run <diagnosis>    log what would run; change nothing
#   heal.sh --status                 print counters / cooldowns
#   heal.sh --reset                  clear heal-state and cooldowns
#   heal.sh --healthy                reset consecutive-fail budget (tunnel is UP)
#   heal.sh --help
#
# Exit codes:
#   0  recovery ran and post-check passed
#   1  recovery ran and post-check failed
#   2  no recovery defined for this diagnosis (or OpenVPN / no ipsec)
#   3  suppressed (disabled, cooldown, budget, daily cap, local outage)
#
# heal-state (key=value lines) lives on the persistent partition:
#   attempts_today          integer
#   attempts_day            YYYY-MM-DD (resets attempts_today)
#   consecutive_fails       integer (resets on healthy)
#   last_cycle_epoch        unix seconds
#   last_result             recovered|failed|suppressed_*|unsupported
#   cooldown_until_epoch    unix seconds
#   exhausted_alerted       0|1
#   capped_alerted          0|1
# =============================================================================

set -u

SCRIPT_DIR="/data/tunnel-monitor"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
STATE_FILE="${SCRIPT_DIR}/heal-state"
LOG_FILE="${SCRIPT_DIR}/heal.log"
LAST_FILE="${SCRIPT_DIR}/heal-last.txt"
LOG_TAG="tunnel-heal"

DRY_RUN=0
FORCE_ENABLE=0
IGNORE_COOLDOWN=0
START_EPOCH="$(date +%s)"
STEP_LINES=""
LADDER_RAN=0

HEAL_ENABLED="${HEAL_ENABLED:-false}"
HEAL_DRY_RUN="${HEAL_DRY_RUN:-false}"
HEAL_MAX_ATTEMPTS="${HEAL_MAX_ATTEMPTS:-3}"
HEAL_COOLDOWN_MINUTES="${HEAL_COOLDOWN_MINUTES:-30}"
HEAL_MAX_PER_DAY="${HEAL_MAX_PER_DAY:-6}"
HEAL_CMD_TIMEOUT="${HEAL_CMD_TIMEOUT:-30}"
HEAL_TOTAL_TIMEOUT="${HEAL_TOTAL_TIMEOUT:-180}"
HEAL_SETTLE_SECONDS="${HEAL_SETTLE_SECONDS:-10}"
HEAL_ALLOW_DAEMON_RESTART="${HEAL_ALLOW_DAEMON_RESTART:-false}"
TUNNEL_IP="${TUNNEL_IP:-}"
IPSEC_CONN_NAME="${IPSEC_CONN_NAME:-}"
REMOTE_LAN_IP="${REMOTE_LAN_IP:-}"
PING_COUNT="${PING_COUNT:-3}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"

attempts_today=0
attempts_day=""
consecutive_fails=0
last_cycle_epoch=0
last_result=""
cooldown_until_epoch=0
exhausted_alerted=0
capped_alerted=0

show_help() {
    cat <<'EOF'
heal.sh — attempt safe, bounded IPsec recovery on the UniFi gateway

USAGE
    heal.sh <diagnosis>
    heal.sh --dry-run <diagnosis>
    heal.sh --status
    heal.sh --reset
    heal.sh --healthy
    heal.sh --help

    Extra flags (before diagnosis):
      --force             ignore HEAL_ENABLED=false (operator CLI)
      --ignore-cooldown   skip cooldown (still respects daily cap)

DIAGNOSES
    TUNNEL_DOWN / TUNNEL DOWN   full recovery ladder
    anything else               exit 2 (no action)

EXIT
    0  recovered     1  still down     2  not healable     3  suppressed

STATE
    /data/tunnel-monitor/heal-state   counters (survives firmware)
    /data/tunnel-monitor/heal.log     audit trail
    /data/tunnel-monitor/heal-last.txt  last cycle summary (email body)
EOF
}

log_line() {
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -d "${SCRIPT_DIR}" ]] && [[ "${DRY_RUN}" -eq 0 ]]; then
        echo "[${ts}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo "[${ts}] ${msg}"
    fi
    logger -t "${LOG_TAG}" -p user.notice "${msg}" 2>/dev/null || true
}

log_step() {
    local line="$1"
    STEP_LINES="${STEP_LINES}    ${line}"$'\n'
    log_line "${line}"
}

load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
    fi
    HEAL_ENABLED="${HEAL_ENABLED:-false}"
    HEAL_DRY_RUN="${HEAL_DRY_RUN:-false}"
    HEAL_MAX_ATTEMPTS="${HEAL_MAX_ATTEMPTS:-3}"
    HEAL_COOLDOWN_MINUTES="${HEAL_COOLDOWN_MINUTES:-30}"
    HEAL_MAX_PER_DAY="${HEAL_MAX_PER_DAY:-6}"
    HEAL_CMD_TIMEOUT="${HEAL_CMD_TIMEOUT:-30}"
    HEAL_TOTAL_TIMEOUT="${HEAL_TOTAL_TIMEOUT:-180}"
    HEAL_SETTLE_SECONDS="${HEAL_SETTLE_SECONDS:-10}"
    HEAL_ALLOW_DAEMON_RESTART="${HEAL_ALLOW_DAEMON_RESTART:-false}"
    TUNNEL_IP="${TUNNEL_IP:-}"
    IPSEC_CONN_NAME="${IPSEC_CONN_NAME:-}"
    REMOTE_LAN_IP="${REMOTE_LAN_IP:-}"
    PING_COUNT="${PING_COUNT:-3}"
    PING_TIMEOUT="${PING_TIMEOUT:-2}"
    if [[ "${HEAL_DRY_RUN}" == "true" ]]; then
        DRY_RUN=1
    fi
}

default_state() {
    attempts_today=0
    attempts_day="$(date '+%Y-%m-%d')"
    consecutive_fails=0
    last_cycle_epoch=0
    last_result=""
    cooldown_until_epoch=0
    exhausted_alerted=0
    capped_alerted=0
}

load_state() {
    default_state
    [[ -f "${STATE_FILE}" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        case "${key}" in
            attempts_today)        attempts_today="${val}" ;;
            attempts_day)          attempts_day="${val}" ;;
            consecutive_fails)     consecutive_fails="${val}" ;;
            last_cycle_epoch)      last_cycle_epoch="${val}" ;;
            last_result)           last_result="${val}" ;;
            cooldown_until_epoch)  cooldown_until_epoch="${val}" ;;
            exhausted_alerted)     exhausted_alerted="${val}" ;;
            capped_alerted)        capped_alerted="${val}" ;;
        esac
    done < "${STATE_FILE}"
    local today
    today="$(date '+%Y-%m-%d')"
    if [[ "${attempts_day}" != "${today}" ]]; then
        attempts_today=0
        attempts_day="${today}"
        capped_alerted=0
    fi
}

save_state() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        return 0
    fi
    mkdir -p "${SCRIPT_DIR}"
    local tmp="${STATE_FILE}.tmp"
    cat > "${tmp}" <<EOF
attempts_today=${attempts_today}
attempts_day=${attempts_day}
consecutive_fails=${consecutive_fails}
last_cycle_epoch=${last_cycle_epoch}
last_result=${last_result}
cooldown_until_epoch=${cooldown_until_epoch}
exhausted_alerted=${exhausted_alerted}
capped_alerted=${capped_alerted}
EOF
    mv "${tmp}" "${STATE_FILE}"
}

timed() {
    timeout "${HEAL_CMD_TIMEOUT}" "$@"
}

budget_remaining() {
    echo $((HEAL_TOTAL_TIMEOUT - ($(date +%s) - START_EPOCH)))
}

budget_ok() {
    local left
    left="$(budget_remaining)"
    [[ "${left}" -gt 5 ]]
}

write_last_report() {
    local result="$1"
    local next_eligible="$2"
    local enabled_txt="yes"
    [[ "${HEAL_ENABLED}" == "true" || "${FORCE_ENABLE}" -eq 1 ]] || enabled_txt="no"
    local last_human="n/a"
    if [[ "${last_cycle_epoch}" -gt 0 ]]; then
        last_human="$(date -d "@${last_cycle_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || date -r "${last_cycle_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || echo "${last_cycle_epoch}")"
    fi
    local conn_label="${IPSEC_CONN_NAME:-<conn-name>}"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        mkdir -p "${SCRIPT_DIR}"
    fi
    local body
    body=$(cat <<EOF
[ Self-Healing Attempts ]
  Enabled:            ${enabled_txt}
  Attempts today:     ${attempts_today} of ${HEAL_MAX_PER_DAY}
  Consecutive fails:  ${consecutive_fails} of ${HEAL_MAX_ATTEMPTS}
  Last cycle:         ${last_human}
${STEP_LINES}  Result:             ${result}
  Next eligible:      ${next_eligible}
EOF
)
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        printf '%s\n' "${body}" > "${LAST_FILE}"
    fi
    printf '%s\n' "${body}"
}

is_healable_diagnosis() {
    local d="$1"
    case "${d}" in
        TUNNEL_DOWN|"TUNNEL DOWN") return 0 ;;
        *) return 1 ;;
    esac
}

is_openvpn_deployment() {
    command -v ipsec >/dev/null 2>&1 || return 1
    timed pgrep -x openvpn >/dev/null 2>&1 || return 1
    if timed ip -o link show 2>/dev/null | grep -qE '^[0-9]+: (vti|ipsec)'; then
        return 1
    fi
    return 0
}

local_internet_up() {
    timed ping -c 1 -W "${PING_TIMEOUT}" -q 1.1.1.1 >/dev/null 2>&1
}

listening_has_tunnel_ip() {
    [[ -n "${TUNNEL_IP}" ]] || return 1
    timed ipsec statusall 2>/dev/null | awk '/Listening IP addresses:/,/^$/' | grep -F -q "${TUNNEL_IP}"
}

sa_count_zero() {
    timed ipsec statusall 2>/dev/null | grep -Eiq '[[:space:]]0 up,[[:space:]]*0 connecting'
}

conn_loaded() {
    if [[ -z "${IPSEC_CONN_NAME}" ]]; then
        timed ipsec statusall 2>/dev/null | grep -qE 'Security Associations'
        return $?
    fi
    timed ipsec statusall 2>/dev/null | grep -F -q "${IPSEC_CONN_NAME}"
}

conn_established() {
    timed ipsec statusall 2>/dev/null | grep -q "ESTABLISHED"
}

ping_remote_lan() {
    [[ -n "${REMOTE_LAN_IP}" ]] || return 1
    timed ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" -q "${REMOTE_LAN_IP}" >/dev/null 2>&1
}

iface_state_down() {
    local iface="$1"
    timed ip -o link show "${iface}" 2>/dev/null | grep -q "state DOWN"
}

discover_iface() {
    local iface=""
    if [[ -n "${TUNNEL_IP}" ]]; then
        iface="$(timed ip -o addr show 2>/dev/null | awk -v ip="${TUNNEL_IP}" '$0 ~ ip {print $2}' | head -1)"
        iface="${iface%%@*}"
    fi
    if [[ -z "${iface}" ]]; then
        iface="$(timed ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | sed 's/@.*//' | grep -E '^(vti|ipsec|tun)' | head -1)"
    fi
    printf '%s' "${iface}"
}

do_or_log() {
    local desc="$1"; shift
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_step "WOULD: ${desc}: $*"
        return 0
    fi
    log_step "RUN: ${desc}: $*"
    timed "$@"
    local rc=$?
    log_step "  exit ${rc}"
    return "${rc}"
}

settle() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_step "WOULD: sleep ${HEAL_SETTLE_SECONDS}s"
        return 0
    fi
    timed sleep "${HEAL_SETTLE_SECONDS}" || sleep "${HEAL_SETTLE_SECONDS}"
}

maybe_step4_restart() {
    do_or_log "pkill charon" pkill -9 charon || true
    do_or_log "pkill starter" pkill -9 starter || true
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_step "WOULD: sleep 2; rm PID files; ipsec start"
        return 0
    fi
    timed sleep 2 || sleep 2
    do_or_log "remove charon pid" rm -f /var/run/charon.pid /var/run/starter.charon.pid || true
    do_or_log "ipsec start" ipsec start
}

run_steps_1_to_3() {
    local iface="$1"
    local step1_ran=0

    # Step 1 — bring tunnel interface UP
    if [[ -z "${iface}" ]]; then
        log_step "step 1  bring interface up      SKIPPED (no tunnel interface found)"
    elif [[ -n "${TUNNEL_IP}" ]] && listening_has_tunnel_ip; then
        log_step "step 1  bring interface up      SKIPPED (TUNNEL_IP already in Listening IPs)"
    elif ! iface_state_down "${iface}"; then
        log_step "step 1  bring interface up      SKIPPED (interface already UP)"
    else
        do_or_log "ip link set up" ip link set "${iface}" up || true
        step1_ran=1
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_step "step 1  bring interface up      DRY-RUN"
        elif listening_has_tunnel_ip; then
            log_step "step 1  bring interface up      OK (Listening IP present)"
            return 0
        else
            log_step "step 1  bring interface up      post-check failed (Listening IP still missing)"
        fi
    fi

    if ! budget_ok; then
        log_step "step 2  ipsec reload            SKIPPED (total timeout)"
        return 1
    fi

    # Step 2 — reload
    if [[ "${step1_ran}" -eq 1 ]] || listening_has_tunnel_ip || sa_count_zero || [[ "${DRY_RUN}" -eq 1 ]]; then
        do_or_log "ipsec reload" ipsec reload || true
        settle
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_step "step 2  ipsec reload            DRY-RUN"
        elif conn_loaded; then
            log_step "step 2  ipsec reload            OK (connection loaded)"
        else
            log_step "step 2  ipsec reload            post-check failed (connection not loaded)"
        fi
    else
        log_step "step 2  ipsec reload            SKIPPED (precondition not met)"
    fi

    if conn_established || ping_remote_lan; then
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            return 0
        fi
    fi

    if ! budget_ok; then
        log_step "step 3  ipsec up                SKIPPED (total timeout)"
        return 1
    fi

    # Step 3 — ipsec up
    if [[ -z "${IPSEC_CONN_NAME}" ]]; then
        log_step "step 3  ipsec up <conn>         SKIPPED (IPSEC_CONN_NAME unset)"
        return 1
    fi
    do_or_log "ipsec up" ipsec up "${IPSEC_CONN_NAME}" || true
    settle
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_step "step 3  ipsec up ${IPSEC_CONN_NAME}         DRY-RUN"
        return 0
    fi
    if conn_established || ping_remote_lan; then
        log_step "step 3  ipsec up ${IPSEC_CONN_NAME}         OK"
        return 0
    fi
    log_step "step 3  ipsec up ${IPSEC_CONN_NAME}         FAILED (peer not responding)"
    return 1
}

next_eligible_text() {
    local until_e="$1"
    local now
    now="$(date +%s)"
    if [[ "${until_e}" -le "${now}" ]]; then
        echo "now"
        return
    fi
    date -d "@${until_e}" '+%Y-%m-%d %H:%M:%S (cooldown)' 2>/dev/null \
        || date -r "${until_e}" '+%Y-%m-%d %H:%M:%S (cooldown)' 2>/dev/null \
        || echo "epoch ${until_e}"
}

print_status() {
    load_config
    load_state
    local enabled="${HEAL_ENABLED}"
    local now left
    now="$(date +%s)"
    left=0
    if [[ "${cooldown_until_epoch}" -gt "${now}" ]]; then
        left=$(( (cooldown_until_epoch - now) / 60 ))
    fi
    echo "[ Self-Healing ]"
    echo "  Enabled:           ${enabled}  dry-run=${HEAL_DRY_RUN}"
    echo "  Attempts today:    ${attempts_today} of ${HEAL_MAX_PER_DAY}"
    echo "  Consecutive fails: ${consecutive_fails} of ${HEAL_MAX_ATTEMPTS}"
    echo "  Cooldown remaining:${left} min  last_result=${last_result:-n/a}"
    if [[ -f "${LAST_FILE}" ]]; then
        echo
        cat "${LAST_FILE}"
    fi
}

cmd_healthy() {
    load_config
    DRY_RUN=0
    load_state
    consecutive_fails=0
    exhausted_alerted=0
    last_result="healthy"
    save_state
}

cmd_reset() {
    load_config
    default_state
    DRY_RUN=0
    save_state
    if [[ -f "${LAST_FILE}" ]]; then
        : > "${LAST_FILE}"
    fi
    log_line "heal-state reset"
    echo "Heal state reset."
}

run_ladder() {
    local diagnosis="$1"
    load_config
    load_state
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        mkdir -p "${SCRIPT_DIR}"
        touch "${LOG_FILE}" 2>/dev/null || true
    fi

    if ! is_healable_diagnosis "${diagnosis}"; then
        last_result="unsupported"
        STEP_LINES="    (no ladder for diagnosis '${diagnosis}')"$'\n'
        write_last_report "not healable" "n/a"
        save_state
        return 2
    fi

    if is_openvpn_deployment; then
        last_result="unsupported"
        log_line "OpenVPN deployment detected — IPsec ladder skipped"
        STEP_LINES="    skipped (OpenVPN in use; IPsec heal not applicable)"$'\n'
        write_last_report "not healable (OpenVPN)" "n/a"
        save_state
        return 2
    fi

    # Dry-run prints the ladder with no rails and no writes.
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        last_cycle_epoch="$(date +%s)"
        log_line "heal dry-run diagnosis=${diagnosis}"
        local iface
        iface="$(discover_iface)"
        log_line "discovered interface: ${iface:-<none>}"
        run_steps_1_to_3 "${iface}" || true
        if [[ "${HEAL_ALLOW_DAEMON_RESTART}" == "true" ]]; then
            log_step "step 4  daemon restart          DRY-RUN (would restart + retry 1-3)"
        else
            log_step "step 4  daemon restart          DISABLED"
        fi
        last_result="dry_run"
        write_last_report "dry-run (no changes)" "n/a"
        return 0
    fi

    if ! command -v ipsec >/dev/null 2>&1; then
        last_result="unsupported"
        log_line "ipsec binary not found — IPsec ladder skipped"
        STEP_LINES="    skipped (ipsec not installed)"$'\n'
        write_last_report "not healable (no ipsec)" "n/a"
        save_state
        return 2
    fi

    if [[ "${FORCE_ENABLE}" -eq 0 && "${HEAL_ENABLED}" != "true" ]]; then
        last_result="suppressed_disabled"
        STEP_LINES="    skipped (HEAL_ENABLED=false)"$'\n'
        write_last_report "suppressed — disabled" "n/a"
        save_state
        return 3
    fi

    if ! local_internet_up; then
        last_result="suppressed_local_outage"
        log_line "skip heal: ping 1.1.1.1 failed (local outage)"
        STEP_LINES="    skipped (local internet down — ping 1.1.1.1 failed)"$'\n'
        write_last_report "suppressed — local outage" "n/a"
        save_state
        return 3
    fi

    local now
    now="$(date +%s)"
    if [[ "${IGNORE_COOLDOWN}" -eq 0 && "${cooldown_until_epoch}" -gt "${now}" ]]; then
        last_result="suppressed_cooldown"
        STEP_LINES="    skipped (cooldown active until $(next_eligible_text "${cooldown_until_epoch}"))"$'\n'
        write_last_report "suppressed — cooldown" "$(next_eligible_text "${cooldown_until_epoch}")"
        save_state
        return 3
    fi

    if [[ "${consecutive_fails}" -ge "${HEAL_MAX_ATTEMPTS}" ]]; then
        last_result="suppressed_budget"
        STEP_LINES="    skipped (consecutive fail budget exhausted)"$'\n'
        write_last_report "heal exhausted" "$(next_eligible_text "${cooldown_until_epoch}")"
        save_state
        return 3
    fi

    if [[ "${attempts_today}" -ge "${HEAL_MAX_PER_DAY}" ]]; then
        last_result="suppressed_cap"
        STEP_LINES="    skipped (daily cap reached)"$'\n'
        write_last_report "heal capped — investigate root cause" "tomorrow"
        save_state
        return 3
    fi

    LADDER_RAN=1
    last_cycle_epoch="$(date +%s)"
    attempts_today=$((attempts_today + 1))
    log_line "heal cycle start diagnosis=${diagnosis} dry_run=${DRY_RUN} iface probe"

    local iface
    iface="$(discover_iface)"
    log_line "discovered interface: ${iface:-<none>}"

    local recovered=1
    if run_steps_1_to_3 "${iface}"; then
        recovered=0
    fi

    if [[ "${recovered}" -ne 0 && "${HEAL_ALLOW_DAEMON_RESTART}" == "true" && "${DRY_RUN}" -eq 0 ]]; then
        if budget_ok; then
            log_step "step 4  daemon restart          RUN"
            maybe_step4_restart
            settle
            if run_steps_1_to_3 "${iface}"; then
                recovered=0
            fi
        else
            log_step "step 4  daemon restart          SKIPPED (total timeout)"
        fi
    else
        if [[ "${HEAL_ALLOW_DAEMON_RESTART}" == "true" && "${DRY_RUN}" -eq 1 ]]; then
            log_step "step 4  daemon restart          DRY-RUN (would restart + retry 1-3)"
        else
            log_step "step 4  daemon restart          DISABLED"
        fi
    fi

    cooldown_until_epoch=$(( $(date +%s) + HEAL_COOLDOWN_MINUTES * 60 ))

    if [[ "${recovered}" -eq 0 ]] && ping_remote_lan; then
        consecutive_fails=0
        exhausted_alerted=0
        capped_alerted=0
        last_result="recovered"
        save_state
        write_last_report "recovered" "$(next_eligible_text "${cooldown_until_epoch}")"
        log_line "heal cycle recovered"
        return 0
    fi

    consecutive_fails=$((consecutive_fails + 1))
    last_result="failed"
    if [[ "${consecutive_fails}" -ge "${HEAL_MAX_ATTEMPTS}" ]]; then
        last_result="failed_exhausted"
    fi
    if [[ "${attempts_today}" -ge "${HEAL_MAX_PER_DAY}" ]]; then
        last_result="failed_capped"
    fi
    save_state
    write_last_report "not recovered" "$(next_eligible_text "${cooldown_until_epoch}")"
    log_line "heal cycle failed consecutive_fails=${consecutive_fails}"
    return 1
}

# ---- argv ------------------------------------------------------------------
DIAGNOSIS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help; exit 0 ;;
        --status)  load_config; print_status; exit 0 ;;
        --reset)   cmd_reset; exit 0 ;;
        --healthy) cmd_healthy; exit 0 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE_ENABLE=1; shift ;;
        --ignore-cooldown) IGNORE_COOLDOWN=1; shift ;;
        --) shift; break ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            show_help
            exit 2
            ;;
        *)
            DIAGNOSIS="$1"
            shift
            break
            ;;
    esac
done
if [[ -z "${DIAGNOSIS}" && $# -gt 0 ]]; then
    DIAGNOSIS="$1"
fi

if [[ -z "${DIAGNOSIS}" ]]; then
    echo "ERROR: diagnosis argument required (or use --status / --reset / --help)" >&2
    exit 2
fi

run_ladder "${DIAGNOSIS}"
exit $?
