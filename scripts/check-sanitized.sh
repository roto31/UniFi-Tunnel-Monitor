#!/bin/bash
# check-sanitized.sh — fail if tracked files contain site-identifying data.
#
# Usage: scripts/check-sanitized.sh [--help]
#
# Scans git-tracked text files for:
#   - personal mailbox addresses (iCloud, Gmail, Outlook, Yahoo, ...)
#   - dynamic-DNS hostnames (No-IP, DuckDNS, DynDNS, ...)
#   - public IPv4 addresses outside private, CGNAT and documentation ranges
#   - every ERE in $SANITIZE_PATTERNS_FILE, when set (keep that file out of git)
#
# Exact tokens listed in .sanitize-allowlist (one per line, # comments) are ignored.
# Exit codes: 0 clean, 1 findings, 2 usage error, 3 missing dependency.
set -euo pipefail

case "${1:-}" in
    "") ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 3; }
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

ALLOWLIST_FILE="${REPO_ROOT}/.sanitize-allowlist"
SELF_PATH="scripts/check-sanitized.sh"
MAILBOX_RE='[A-Za-z0-9._%+-]+@(mac|me|icloud|gmail|googlemail|outlook|hotmail|live|yahoo|proton|protonmail)\.(com|me)'
DDNS_RE='[A-Za-z0-9-]+\.(onthewifi\.com|ddns\.net|hopto\.org|zapto\.org|sytes\.net|servebeer\.com|myftp\.org|duckdns\.org|dyndns\.org|dynu\.net|freeddns\.org)'
IPV4_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'
FINDINGS=0

is_allowlisted() {
    local token="$1"
    [[ -f "${ALLOWLIST_FILE}" ]] || return 1
    grep -v '^[[:space:]]*#' "${ALLOWLIST_FILE}" | grep -qxF -- "${token}"
}

is_public_ipv4() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    for octet in "${a}" "${b}" "${c}" "${d}"; do
        (( 10#${octet} <= 255 )) || return 1
    done
    a=$((10#${a})); b=$((10#${b})); c=$((10#${c}))
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    case "$1" in
        1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9|149.112.112.112|208.67.222.222|208.67.220.220) return 1 ;;
    esac
    return 0
}

report() {
    echo "FINDING: $1: $2"
    FINDINGS=$((FINDINGS + 1))
}

scan_tokens() {
    local label="$1" pattern="$2" location token
    while IFS= read -r line; do
        location="${line%:*}"
        token="${line##*:}"
        [[ "${location%%:*}" == "${SELF_PATH}" ]] && continue
        is_allowlisted "${token}" && continue
        report "${location}" "${label} ${token}"
    done < <(git grep -n -I -o -E -e "${pattern}" -- . ':!.sanitize-allowlist' || true)
}

scan_ipv4() {
    local line location token
    while IFS= read -r line; do
        location="${line%:*}"
        token="${line##*:}"
        [[ "${location%%:*}" == "${SELF_PATH}" ]] && continue
        is_public_ipv4 "${token}" || continue
        is_allowlisted "${token}" && continue
        report "${location}" "public IPv4 ${token}"
    done < <(git grep -n -I -o -E -e "${IPV4_RE}" -- . ':!.sanitize-allowlist' || true)
}

scan_private_patterns() {
    [[ -n "${SANITIZE_PATTERNS_FILE:-}" ]] || return 0
    if [[ ! -r "${SANITIZE_PATTERNS_FILE}" ]]; then
        echo "ERROR: SANITIZE_PATTERNS_FILE not readable: ${SANITIZE_PATTERNS_FILE}" >&2
        exit 2
    fi
    local line
    while IFS= read -r line; do
        report "${line}" "private pattern (text hidden)"
    done < <(git grep -n -I -E -f "${SANITIZE_PATTERNS_FILE}" -- . ':!.sanitize-allowlist' | cut -d: -f1,2 || true)
}

scan_tokens "mailbox" "${MAILBOX_RE}"
scan_tokens "dynamic DNS host" "${DDNS_RE}"
scan_ipv4
scan_private_patterns

if (( FINDINGS > 0 )); then
    echo "ERROR: ${FINDINGS} finding(s). Replace with placeholders or add exact tokens to .sanitize-allowlist." >&2
    exit 1
fi
echo "Sanitization check passed."
