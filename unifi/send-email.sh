#!/bin/bash
# =============================================================================
# Email sender — submits via iCloud SMTP using curl's built-in SMTP support
# Usage: send-email.sh "Subject line" "Body text"
# =============================================================================

set -u

SCRIPT_DIR="/data/tunnel-monitor"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file missing: $CONFIG_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Required vars (set in config.env):
#   SMTP_USER      — full iCloud address, e.g. REPLACE_WITH_EMAIL
#   SMTP_PASSWORD  — App-specific password from appleid.apple.com
#   ALERT_FROM     — must match SMTP_USER (iCloud enforces this)
#   ALERT_TO       — where to send alerts

: "${SMTP_USER:?SMTP_USER must be set in config.env}"
: "${SMTP_PASSWORD:?SMTP_PASSWORD must be set in config.env}"
: "${ALERT_FROM:?ALERT_FROM must be set in config.env}"
: "${ALERT_TO:?ALERT_TO must be set in config.env}"

SUBJECT="${1:-No subject}"
BODY="${2:-No body}"

SMTP_SERVER="${SMTP_SERVER:-smtp.mail.me.com}"
SMTP_PORT="${SMTP_PORT:-587}"

# Build RFC822 message
DATE_HEADER=$(date -R)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" <<EOF
From: ${ALERT_FROM}
To: ${ALERT_TO}
Subject: ${SUBJECT}
Date: ${DATE_HEADER}
Content-Type: text/plain; charset=UTF-8
MIME-Version: 1.0

${BODY}
EOF

# Send via curl (STARTTLS on 587)
curl --silent --show-error --ssl-reqd \
    --url "smtp://${SMTP_SERVER}:${SMTP_PORT}" \
    --user "${SMTP_USER}:${SMTP_PASSWORD}" \
    --mail-from "${ALERT_FROM}" \
    --mail-rcpt "${ALERT_TO}" \
    --upload-file "$TMPFILE" \
    --connect-timeout 15 \
    --max-time 30

CURL_EXIT=$?
if [[ $CURL_EXIT -ne 0 ]]; then
    logger -t tunnel-monitor -p user.err "Email send failed (curl exit ${CURL_EXIT})"
    exit $CURL_EXIT
fi

logger -t tunnel-monitor -p user.info "Alert email sent: ${SUBJECT}"
exit 0
