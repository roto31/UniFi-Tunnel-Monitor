#!/bin/bash
# =============================================================================
# spoke-policy-check.sh — spoke gateway writer for the policy-state file
# =============================================================================
# Runs on the spoke gateway (systemd timer). Reads that gateway's policy-based
# routing rules and writes one line the Mac already knows how to read:
#   0:UP    source network is marked into a tunnel routing table
#   N:UP    recent failures, threshold not crossed
#   N:DOWN  threshold crossed; traffic is not using the tunnel
#
# UniFi applies a traffic route by adding the source network to an ipset,
# MARKing those packets, and looking the mark up in a tunnel table (tun/vti/wg).
# A blackhole table (kill switch with the tunnel down) is DOWN.
#
# Exit codes: 0 wrote a state line, 1 runtime failure before a write, 2 config.
# =============================================================================

set -euo pipefail

CONFIG_FILE="${POLICY_CHECK_CONFIG:-/data/tunnel-monitor/policy-check.env}"
STATE_FILE="/data/tunnel-monitor/policy-state"
FAILURE_THRESHOLD=3
TUNNEL_DEV_RE='^(tun|vtun|vti|wg)[0-9]+$'
POLICY_SOURCE_CIDR=""
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

show_help() {
    cat <<'EOF'
spoke-policy-check.sh — write the spoke policy-state file

USAGE
    spoke-policy-check.sh
    spoke-policy-check.sh --self-test
    spoke-policy-check.sh --help

Reads policy-check.env (POLICY_SOURCE_CIDR, optional FAILURE_THRESHOLD,
TUNNEL_DEV_RE, POLICY_STATE_PATH). Writes N:UP or N:DOWN atomically.
EOF
}

log_line() {
    logger -t tunnel-monitor-policy "$*" 2>/dev/null || true
    printf '%s\n' "$*"
}

valid_mark() {
    [[ "$1" =~ ^0x[0-9A-Fa-f]+/0x[0-9A-Fa-f]+$ ]]
}

mark_selects_rule() {
    local xmark="$1" fwmark="$2" xv xm fv fm result masked expect
    valid_mark "${xmark}" || return 1
    valid_mark "${fwmark}" || return 1
    xv="${xmark%%/*}"
    xm="${xmark##*/}"
    fv="${fwmark%%/*}"
    fm="${fwmark##*/}"
    result=$((xv))
    masked=$((result & fm))
    expect=$((fv & fm))
    [[ "${masked}" -eq "${expect}" ]]
}

dev_is_tunnel() {
    printf '%s\n' "$1" | grep -Eq "${TUNNEL_DEV_RE}"
}

src_set_from_mark_line() {
    local line="$1" name
    [[ "${line}" == *"-j MARK"* && "${line}" == *"--set-xmark"* ]] || return 1
    name="$(printf '%s\n' "${line}" | sed -n 's/.*--match-set \([^ ]*\) src.*/\1/p')"
    [[ -n "${name}" ]] || return 1
    if printf '%s\n' "${line}" | grep -q "! --match-set ${name} src"; then
        return 1
    fi
    printf '%s\n' "${name}"
}

xmark_from_line() {
    local line="$1" mark
    mark="$(printf '%s\n' "${line}" | sed -n 's/.*--set-xmark \([0-9A-Fa-fxX]*\/[0-9A-Fa-fxX]*\).*/\1/p')"
    valid_mark "${mark}" || return 1
    printf '%s\n' "${mark}"
}

table_uses_tunnel() {
    local table="$1" line dev routes
    routes="$(ip route show table "${table}" 2>/dev/null || true)"
    [[ -n "${routes}" ]] || return 1
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        case "${line}" in
            blackhole*|unreachable*|prohibit*) continue ;;
        esac
        dev="$(printf '%s\n' "${line}" | sed -n 's/.*dev \([^ ]*\).*/\1/p')"
        [[ -n "${dev}" ]] || continue
        if dev_is_tunnel "${dev}"; then
            return 0
        fi
    done <<< "${routes}"
    return 1
}

table_for_xmark() {
    local xmark="$1" line fw table
    while IFS= read -r line; do
        fw="$(printf '%s\n' "${line}" | sed -n 's/.*fwmark \([0-9A-Fa-fxX]*\/[0-9A-Fa-fxX]*\).*/\1/p')"
        [[ -n "${fw}" ]] || continue
        mark_selects_rule "${xmark}" "${fw}" || continue
        table="$(printf '%s\n' "${line}" | sed -n 's/.*lookup \([^ ]*\).*/\1/p')"
        [[ -n "${table}" ]] || continue
        if table_uses_tunnel "${table}"; then
            printf '%s\n' "${table}"
            return 0
        fi
    done <<< "$(ip rule show 2>/dev/null || true)"
    return 1
}

set_members() {
    ipset list "$1" 2>/dev/null | awk '/Members:/{p=1; next} p && NF {print} p && !NF {exit}'
}

set_contains_source() {
    local name="$1" member
    if ipset test "${name}" "${POLICY_SOURCE_CIDR}" >/dev/null 2>&1; then
        return 0
    fi
    if set_members "${name}" | grep -Fq "${POLICY_SOURCE_CIDR}"; then
        return 0
    fi
    # UniFi list:set entries name the hash:net set that holds the prefix.
    while IFS= read -r member; do
        [[ "${member}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || continue
        if ipset test "${member}" "${POLICY_SOURCE_CIDR}" >/dev/null 2>&1; then
            return 0
        fi
        if set_members "${member}" | grep -Fq "${POLICY_SOURCE_CIDR}"; then
            return 0
        fi
    done <<< "$(set_members "${name}")"
    return 1
}

policy_route_up() {
    local line src_set xmark table pbr
    REASON="traffic route for ${POLICY_SOURCE_CIDR} not found"
    if ! pbr="$(iptables -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null)"; then
        REASON="policy-routing chain unavailable"
        return 1
    fi
    while IFS= read -r line; do
        src_set="$(src_set_from_mark_line "${line}" || true)"
        [[ -n "${src_set}" ]] || continue
        set_contains_source "${src_set}" || continue
        xmark="$(xmark_from_line "${line}" || true)"
        [[ -n "${xmark}" ]] || continue
        if table="$(table_for_xmark "${xmark}")"; then
            REASON="routed via ${table}"
            return 0
        fi
        REASON="source matches a traffic route but the lookup table is not a tunnel"
    done <<< "${pbr}"
    return 1
}

write_state_line() {
    local line="$1" tmp
    tmp="${STATE_FILE}.tmp"
    printf '%s\n' "${line}" > "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
}

next_state_line() {
    local up="$1" prev count
    if [[ -f "${STATE_FILE}" ]]; then
        prev="$(tr -d '[:space:]' < "${STATE_FILE}")"
    else
        prev="0:UP"
    fi
    if [[ "${up}" == "yes" ]]; then
        printf '%s\n' "0:UP"
        return 0
    fi
    count="${prev%%:*}"
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        count=0
    fi
    count=$((10#${count} + 1))
    if [[ "${count}" -ge "${FAILURE_THRESHOLD}" ]]; then
        printf '%s\n' "${count}:DOWN"
    else
        printf '%s\n' "${count}:UP"
    fi
}

run_self_test() {
    local failed=0 line
    mark_selects_rule "0x6b0000/0x7f0000" "0x6a0000/0x7e0000" || failed=1
    if mark_selects_rule "0x1a0000/0x7e0000" "0x6a0000/0x7e0000"; then
        failed=1
    fi
    dev_is_tunnel "tun1" || failed=1
    if dev_is_tunnel "eth4"; then
        failed=1
    fi
    line='-A UBIOS_PREROUTING_PBR -m set --match-set EXAMPLE_set src -m set ! --match-set EXAMPLE_local dst -j MARK --set-xmark 0x6b0000/0x7f0000'
    [[ "$(src_set_from_mark_line "${line}")" == "EXAMPLE_set" ]] || failed=1
    [[ "$(xmark_from_line "${line}")" == "0x6b0000/0x7f0000" ]] || failed=1
    line='-A UBIOS_PREROUTING_PBR -m set ! --match-set EXAMPLE_set src -j MARK --set-xmark 0x6b0000/0x7f0000'
    if src_set_from_mark_line "${line}" >/dev/null 2>&1; then
        failed=1
    fi
    if [[ "${failed}" -ne 0 ]]; then
        echo "ERROR: self-test failed" >&2
        exit 1
    fi
    echo "self-test passed"
}

load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: missing ${CONFIG_FILE}" >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    POLICY_SOURCE_CIDR="${POLICY_SOURCE_CIDR:-}"
    STATE_FILE="${POLICY_STATE_PATH:-${STATE_FILE}}"
    FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
    TUNNEL_DEV_RE="${TUNNEL_DEV_RE:-^(tun|vtun|vti|wg)[0-9]+$}"
    if [[ ! "${POLICY_SOURCE_CIDR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "ERROR: POLICY_SOURCE_CIDR must be an IPv4 prefix" >&2
        exit 2
    fi
    if [[ ! "${STATE_FILE}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        echo "ERROR: POLICY_STATE_PATH is not a safe absolute path" >&2
        exit 2
    fi
    if [[ ! "${FAILURE_THRESHOLD}" =~ ^[0-9]+$ ]] || [[ "${FAILURE_THRESHOLD}" -lt 1 ]]; then
        echo "ERROR: FAILURE_THRESHOLD must be a positive integer" >&2
        exit 2
    fi
}

main() {
    local up="no" line
    load_config
    if policy_route_up; then
        up="yes"
    fi
    line="$(next_state_line "${up}")"
    write_state_line "${line}"
    log_line "policy-state ${line} (${REASON})"
}

case "${1:-}" in
    --help|-h|help) show_help; exit 0 ;;
    --self-test)    run_self_test; exit 0 ;;
    "")             main ;;
    *)
        echo "ERROR: unknown argument: $1" >&2
        show_help >&2
        exit 1
        ;;
esac
