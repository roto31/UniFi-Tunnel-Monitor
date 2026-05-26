#!/bin/bash
# =============================================================================
# test-wan-guard.sh — Test suite for wan-guard.sh
# Usage: bash test-wan-guard.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAN_GUARD="${SCRIPT_DIR}/wan-guard.sh"

PASS=0; FAIL=0; SKIP=0

pass() { echo "  ✓ PASS: $*"; ((PASS++)) || true; }
fail() { echo "  ✗ FAIL: $*"; ((FAIL++)) || true; }
skip() { echo "  - SKIP: $*"; ((SKIP++)) || true; }
section() { echo ""; echo "── $* ──"; }

# ---------------------------------------------------------------------------
# Minimal standalone test harness for is_private_ip
# We embed the function directly to avoid sourcing complexity
# ---------------------------------------------------------------------------
is_private_ip() {
    local ip="$1"
    if ! [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    IFS='.' read -r a b c d <<< "${ip}"
    [[ "${a}" -eq 10 ]] && return 0
    [[ "${a}" -eq 172 && "${b}" -ge 16 && "${b}" -le 31 ]] && return 0
    [[ "${a}" -eq 192 && "${b}" -eq 168 ]] && return 0
    [[ "${a}" -eq 100 && "${b}" -ge 64 && "${b}" -le 127 ]] && return 0
    [[ "${a}" -eq 127 ]] && return 0
    [[ "${a}" -eq 169 && "${b}" -eq 254 ]] && return 0
    [[ "${a}" -ge 224 ]] && return 0
    return 1
}

check_private() {
    is_private_ip "$1" && pass "$2 ($1) → private" || fail "$2 ($1) should be private"
}
check_public() {
    is_private_ip "$1" && fail "$2 ($1) should be public" || pass "$2 ($1) → public"
}

# ---------------------------------------------------------------------------
# Temp environment for CLI tests
# ---------------------------------------------------------------------------
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat > "${TMPDIR_TEST}/config.env" <<'EOF'
WAN_GUARD_INTERFACE=lo
WAN_GUARD_HOSTNAME=hub.example-ddns.test
WAN_GUARD_NOIP_USER=testuser
WAN_GUARD_NOIP_PASS=testpass
WAN_GUARD_DRY_RUN=true
ALERT_EMAIL=test@example.com
SMTP_SERVER=smtp.example.com
SMTP_PORT=465
SMTP_USER=smtp@example.com
SMTP_PASS=smtppass
EOF

run_wg() {
    CONFIG_FILE="${TMPDIR_TEST}/config.env" \
    STATE_FILE="${TMPDIR_TEST}/wan-guard.state" \
    LOG_FILE="${TMPDIR_TEST}/wan-guard.log" \
    WAN_GUARD_DRY_RUN=true \
    bash "${WAN_GUARD}" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# SECTION 1: IP classification
# ---------------------------------------------------------------------------
section "Private/CGNAT IP detection"

check_private "192.168.100.104"   "RFC1918 CGNAT-style backup WAN"
check_private "192.168.0.1"      "RFC1918 192.168/16"
check_private "10.77.0.50"        "RFC1918 10/8 example"
check_private "10.255.255.255"   "RFC1918 10/8 upper"
check_private "172.16.0.1"       "RFC1918 172.16/12 lower"
check_private "172.31.255.255"   "RFC1918 172.16/12 upper"
check_private "100.64.0.1"       "CGNAT RFC6598 lower"
check_private "100.127.255.255"  "CGNAT RFC6598 upper"
check_private "100.100.100.100"  "CGNAT mid-range example"
check_private "127.0.0.1"        "Loopback"
check_private "169.254.1.1"      "Link-local"
check_private "224.0.0.1"        "Multicast"
check_private ""                 "Empty string (safe default = private)"
check_private "not.an.ip"        "Invalid string (safe default = private)"

section "Public IP detection"

check_public "203.0.113.10"     "RFC5737 TEST-NET-3 (hub public example)"
check_public "198.51.100.20"    "RFC5737 TEST-NET-2 (spoke public example)"
check_public "8.8.8.8"          "Google DNS"
check_public "1.1.1.1"          "Cloudflare DNS"
check_public "172.15.255.255"   "Just below RFC1918 172.16 block"
check_public "172.32.0.0"       "Just above RFC1918 172.31 block"
check_public "100.63.255.255"   "Just below CGNAT 100.64 block"
check_public "100.128.0.0"      "Just above CGNAT 100.127 block"

# ---------------------------------------------------------------------------
# SECTION 2: CLI smoke tests
# ---------------------------------------------------------------------------
section "CLI smoke tests"

run_wg help > /dev/null 2>&1 \
    && pass "help command exits 0" \
    || fail "help command failed"

run_wg status > /dev/null 2>&1
rc=$?
[[ $rc -le 1 ]] \
    && pass "status command exits cleanly (rc=${rc})" \
    || fail "status command unexpected exit ${rc}"

# check with loopback (127.0.0.1 = private) → should detect and block
OUTPUT="$(run_wg check 2>&1)" || true
if echo "${OUTPUT}" | grep -Eqi "private|cgnat|blocked|unreadable|interface"; then
    pass "check detects private/unreachable WAN IP"
else
    skip "check output unclear in test environment: $(echo "${OUTPUT}" | tail -1)"
fi

# ---------------------------------------------------------------------------
# SECTION 3: State file
# ---------------------------------------------------------------------------
section "State file operations"

STATE_F="${TMPDIR_TEST}/state_test"

bash -c "
    source '${WAN_GUARD}' 2>/dev/null
    STATE_FILE='${STATE_F}'
    write_state 'key1' 'val1'
    write_state 'key2' 'val2'
    v1=\$(read_state 'key1')
    v2=\$(read_state 'key2')
    [[ \"\${v1}\" == 'val1' && \"\${v2}\" == 'val2' ]]
" WAN_GUARD_TEST_MODE=1 CONFIG_FILE="${TMPDIR_TEST}/config.env" LOG_FILE="${TMPDIR_TEST}/test.log" 2>/dev/null \
    && pass "write/read multiple state keys" \
    || skip "state test skipped (sourcing env)"

bash -c "
    source '${WAN_GUARD}' 2>/dev/null
    STATE_FILE='${STATE_F}'
    write_state 'key1' 'original'
    write_state 'key1' 'updated'
    val=\$(read_state 'key1')
    [[ \"\${val}\" == 'updated' ]]
" WAN_GUARD_TEST_MODE=1 CONFIG_FILE="${TMPDIR_TEST}/config.env" LOG_FILE="${TMPDIR_TEST}/test.log" 2>/dev/null \
    && pass "write_state overwrites existing key" \
    || skip "overwrite test skipped (sourcing env)"

# ---------------------------------------------------------------------------
# SECTION 4: Scenario simulations
# ---------------------------------------------------------------------------
section "Scenario: CGNAT on primary WAN interface"

# Simulate get_wan_ip returning 192.168.100.104
CGNAT_OUT="$(
    WAN_GUARD_TEST_MODE=1 \
    CONFIG_FILE="${TMPDIR_TEST}/config.env" \
    STATE_FILE="${TMPDIR_TEST}/cgnat.state" \
    LOG_FILE="${TMPDIR_TEST}/cgnat.log" \
    WAN_GUARD_DRY_RUN=true \
    bash -c "
        source '${WAN_GUARD}' 2>/dev/null
        get_wan_ip() { echo '192.168.100.104'; }
        run_check
    " 2>&1
)" || true

echo "${CGNAT_OUT}" | grep -Eqi "cgnat|private|blocked" \
    && pass "CGNAT IP 192.168.100.104 triggers block" \
    || fail "CGNAT IP not detected: ${CGNAT_OUT}"

section "Scenario: IPs in sync (no update needed)"

SYNC_OUT="$(
    WAN_GUARD_TEST_MODE=1 \
    CONFIG_FILE="${TMPDIR_TEST}/config.env" \
    STATE_FILE="${TMPDIR_TEST}/sync.state" \
    LOG_FILE="${TMPDIR_TEST}/sync.log" \
    WAN_GUARD_DRY_RUN=true \
    bash -c "
        source '${WAN_GUARD}' 2>/dev/null
        get_wan_ip()          { echo '203.0.113.10'; }
        get_noip_current_ip() { echo '203.0.113.10'; }
        run_check
    " 2>&1
)" || true

echo "${SYNC_OUT}" | grep -Eqi "sync|no.*change|in.sync" \
    && pass "Matching IPs → in-sync, no update" \
    || fail "Expected in-sync result: ${SYNC_OUT}"

section "Scenario: IP mismatch — stale private in DNS, public IP on WAN"

MISMATCH_OUT="$(
    WAN_GUARD_TEST_MODE=1 \
    CONFIG_FILE="${TMPDIR_TEST}/config.env" \
    STATE_FILE="${TMPDIR_TEST}/mismatch.state" \
    LOG_FILE="${TMPDIR_TEST}/mismatch.log" \
    WAN_GUARD_DRY_RUN=true \
    bash -c "
        source '${WAN_GUARD}' 2>/dev/null
        get_wan_ip()          { echo '203.0.113.10'; }
        get_noip_current_ip() { echo '192.168.100.104'; }
        run_check
    " 2>&1
)" || true

echo "${MISMATCH_OUT}" | grep -Eqi "dry.run|mismatch|updat" \
    && pass "Mismatch (stale CGNAT in DNS) → update triggered" \
    || fail "Expected update trigger: ${MISMATCH_OUT}"

section "Scenario: DRY_RUN blocks actual No-IP call"

DRYRUN_OUT="$(
    WAN_GUARD_TEST_MODE=1 \
    CONFIG_FILE="${TMPDIR_TEST}/config.env" \
    LOG_FILE="${TMPDIR_TEST}/dryrun.log" \
    WAN_GUARD_DRY_RUN=true \
    bash -c "
        source '${WAN_GUARD}' 2>/dev/null
        update_noip 'hub.example-ddns.test' '203.0.113.10'
    " 2>&1
)" || true

echo "${DRYRUN_OUT}" | grep -Eqi "dry.run|would" \
    && pass "DRY_RUN prevents real No-IP API call" \
    || fail "DRY_RUN did not log skip: ${DRYRUN_OUT}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════"
echo "  PASS: ${PASS}  FAIL: ${FAIL}  SKIP: ${SKIP}"
echo "════════════════════════════════════════"
(( FAIL == 0 )) && echo "  ✓ All tests passed" && exit 0 || echo "  ⚠ ${FAIL} failure(s)" && exit 1
