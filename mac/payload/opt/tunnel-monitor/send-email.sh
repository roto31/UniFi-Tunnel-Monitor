#!/bin/bash
# =============================================================================
# send-email.sh — iCloud SMTP submission for the Mac tunnel monitor
# =============================================================================
# Usage: send-email.sh <subject-without-prefix> <body-file>
#
# Reads SMTP credentials from /opt/tunnel-monitor/config.env. Prepends the
# configured SUBJECT_PREFIX (default "[MAC]") so the operator can tell at a
# glance which vantage point caught the issue.
#
# Exit codes:
#   0  success
#   1  runtime failure (curl, mktemp, etc.)
#   2  config error (missing config.env, missing required vars)
#   3  bad invocation (missing args)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

show_help() {
    cat <<'EOF'
send-email.sh — iCloud SMTP submission for the Mac tunnel monitor

USAGE
    send-email.sh <subject> <body-file>
    send-email.sh --help

ARGUMENTS
    subject     Subject line (SUBJECT_PREFIX is prepended automatically)
    body-file   Path to a file containing the plain-text message body

CONFIG
    Reads SMTP_USER, SMTP_PASSWORD, SMTP_SERVER, SMTP_PORT, ALERT_FROM,
    ALERT_TO, and SUBJECT_PREFIX from /opt/tunnel-monitor/config.env.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

if [[ $# -lt 2 ]]; then
    echo "ERROR: expected 2 arguments, got $#" >&2
    show_help >&2
    exit 3
fi

SUBJECT_RAW="$1"
BODY_FILE="$2"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config file missing: ${CONFIG_FILE}" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

SMTP_SERVER="${SMTP_SERVER:-smtp.mail.me.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SUBJECT_PREFIX="${SUBJECT_PREFIX:-[MAC]}"

for var in SMTP_USER SMTP_PASSWORD ALERT_FROM ALERT_TO; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} not set in ${CONFIG_FILE}" >&2
        exit 2
    fi
done

if [[ "${SMTP_PASSWORD}" == "REPLACE_WITH_APP_SPECIFIC_PASSWORD" ]]; then
    echo "ERROR: SMTP_PASSWORD still set to placeholder value" >&2
    exit 2
fi

if [[ ! -f "${BODY_FILE}" ]]; then
    echo "ERROR: body file missing: ${BODY_FILE}" >&2
    exit 1
fi

SUBJECT="${SUBJECT_PREFIX} ${SUBJECT_RAW}"

build_message() {
    local out="$1"
    {
        printf 'From: %s\r\n' "${ALERT_FROM}"
        printf 'To: %s\r\n' "${ALERT_TO}"
        printf 'Subject: %s\r\n' "${SUBJECT}"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'Message-ID: <%s.%s@%s>\r\n' "$(date +%s)" "$$" "$(hostname -s)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n'
        # Convert body line endings to CRLF for SMTP compliance.
        sed 's/$/\r/' "${BODY_FILE}"
    } > "${out}"
}

TMP_MSG="$(mktemp -t tunnel-monitor-mail.XXXXXX)"
trap 'rm -f "${TMP_MSG}"' EXIT

build_message "${TMP_MSG}"

# Curl with explicit STARTTLS and authenticated submission. Fail loudly on
# anything but 2xx; suppress the password from any debug output.
if ! curl --silent --show-error --fail --ssl-reqd \
        --connect-timeout 10 \
        --max-time 30 \
        --url "smtp://${SMTP_SERVER}:${SMTP_PORT}" \
        --user "${SMTP_USER}:${SMTP_PASSWORD}" \
        --mail-from "${ALERT_FROM}" \
        --mail-rcpt "${ALERT_TO}" \
        --upload-file "${TMP_MSG}" 2>&1; then
    echo "ERROR: SMTP submission failed" >&2
    exit 1
fi

exit 0
