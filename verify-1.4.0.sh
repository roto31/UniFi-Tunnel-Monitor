#!/bin/bash
# verify-1.4.0.sh — gates for Tunnel Monitor 1.4.0 (macOS bash 3.2)
# Stop on the first failed gate. Site addresses are not stored here;
# gate 8 reads REMOTE_WAN_IP from the live config.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/Tunnel Monitor.app"
INSTALL_DIR="/opt/tunnel-monitor"
LABEL="com.ruter.tunnel-monitor"
if [[ -f "${APP}/Contents/Info.plist" ]]; then
    branded="$(/usr/libexec/PlistBuddy -c 'Print :TMLaunchDaemonLabel' "${APP}/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -n "${branded}" ]]; then
        LABEL="${branded}"
    fi
fi

RESULTS=""
FAILED=0

record() {
    RESULTS="${RESULTS}
$1 | $2"
}

fail_gate() {
    local name="$1"
    local repair="$2"
    echo " [FAILED] ${name}"
    echo " Repair: ${repair}"
    record "${name}" "FAILED"
    FAILED=1
    echo
    echo "Completed before failure:"
    printf '%s\n' "${RESULTS}" | sed '/^$/d'
    exit 1
}

pass_gate() {
    echo " [PASSED] $1"
    record "$1" "PASSED"
}

echo "Tunnel Monitor 1.4.0 verification"
echo "Repo: ${ROOT}"

# Gate 1
echo
echo "Gate 1: bash -n"
if /bin/bash -n "${ROOT}/mac/payload/opt/tunnel-monitor/monitor.sh" \
    && /bin/bash -n "${ROOT}/mac/payload/opt/tunnel-monitor/ssh-spoke-state.sh" \
    && /bin/bash -n "${ROOT}/mac/payload/opt/tunnel-monitor/tunnel-check" \
    && /bin/bash -n "${ROOT}/mac/install.sh" \
    && bash -n "${ROOT}/unifi/monitor.sh"; then
    pass_gate "Gate 1 bash -n"
else
    fail_gate "Gate 1 bash -n" "Re-run /bin/bash -n on the script that failed and fix the syntax error."
fi

# Gate 2
echo
echo "Gate 2: swift build -c release"
build_log="$(mktemp -t tm-swift-build.XXXXXX)"
if (cd "${ROOT}/mac/app/TunnelMonitor" && swift build -c release --disable-sandbox >"${build_log}" 2>&1); then
    if grep -E 'warning:' "${build_log}" | grep -E 'MonitorState.swift|StatusPresentation.swift|StatusContentView.swift|AppBranding.swift|WizardFieldModels.swift|ConfigEnvWriter.swift|Actions.swift|SetupWizardView.swift' >/dev/null; then
        echo "Warnings in touched Swift files:"
        grep -E 'warning:' "${build_log}" | grep -E 'MonitorState.swift|StatusPresentation.swift|StatusContentView.swift|AppBranding.swift|WizardFieldModels.swift|ConfigEnvWriter.swift|Actions.swift|SetupWizardView.swift' || true
        fail_gate "Gate 2 swift build" "Fix warnings in the files listed above, then re-run: cd mac/app/TunnelMonitor && swift build -c release"
    fi
    pass_gate "Gate 2 swift build"
else
    tail -40 "${build_log}"
    fail_gate "Gate 2 swift build" "cd \"${ROOT}/mac/app/TunnelMonitor\" && swift build -c release --disable-sandbox"
fi
rm -f "${build_log}"

# Gate 3
echo
echo "Gate 3: fixture decode"
if (cd "${ROOT}/mac/app/TunnelMonitor" && swift test -c release --disable-sandbox --filter SnapshotDecodeTests >/tmp/tm-swift-test.txt 2>&1); then
    pass_gate "Gate 3 fixture decode"
else
    tail -30 /tmp/tm-swift-test.txt
    fail_gate "Gate 3 fixture decode" "cd mac/app/TunnelMonitor && swift test -c release --filter SnapshotDecodeTests"
fi

# Gate 4 — feature off, no spoke SSH
echo
echo "Gate 4: feature-off diagnose"
tmp="$(mktemp -d -t tm-feature-off.XXXXXX)"
marker="${tmp}/spoke-called"
cp "${ROOT}/mac/payload/opt/tunnel-monitor/monitor.sh" "${tmp}/monitor.sh"
cp "${ROOT}/mac/payload/opt/tunnel-monitor/notify.sh" "${tmp}/notify.sh" 2>/dev/null || true
cat > "${tmp}/ssh-router-state.sh" <<'EOF'
#!/bin/bash
echo "0:UP"
EOF
cat > "${tmp}/ssh-spoke-state.sh" <<EOF
#!/bin/bash
echo called >> "${marker}"
exit 1
EOF
cat > "${tmp}/send-email.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "${tmp}/monitor.sh" "${tmp}/ssh-router-state.sh" "${tmp}/ssh-spoke-state.sh" "${tmp}/send-email.sh"
cat > "${tmp}/config.env" <<'EOF'
REMOTE_LAN_IP="127.0.0.1"
REMOTE_WAN_IP="127.0.0.1"
REMOTE_DDNS="localhost"
SPOKE_POLICY_ENABLED="false"
FAILURE_THRESHOLD="3"
PING_COUNT="1"
PING_TIMEOUT="1"
SUBJECT_PREFIX="[MAC]"
NOTIFY_SOUND_DOWN="Glass"
NOTIFY_SOUND_RECOVERY="Hero"
EOF
diag="$("${tmp}/monitor.sh" diagnose 2>/dev/null || true)"
lines="$(printf '%s\n' "${diag}" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ -f "${marker}" ]]; then
    fail_gate "Gate 4 feature-off" "monitor.sh called ssh-spoke-state.sh while SPOKE_POLICY_ENABLED=false. Do not call read_spoke_state unless the feature is true."
fi
if [[ "${lines}" -ne 6 ]]; then
    printf '%s\n' "${diag}"
    fail_gate "Gate 4 feature-off" "Feature-off diagnose must print the same 6 lines as 1.3.1 and nothing else."
fi
case "${diag}" in
    Diagnosis:*) pass_gate "Gate 4 feature-off" ;;
    *) fail_gate "Gate 4 feature-off" "diagnose output did not start with Diagnosis:" ;;
esac
rm -rf "${tmp}"

# Gate 5
echo
echo "Gate 5: installed app"
if [[ ! -d "${APP}" ]]; then
    fail_gate "Gate 5 app version" "Copy build/dist/Tunnel Monitor.app to /Applications/Tunnel Monitor.app"
fi
ver="$(defaults read "${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")"
if [[ "${ver}" != "1.4.0" ]]; then
    echo "version=${ver}"
    fail_gate "Gate 5 app version" "Rebuild with VERSION=1.4.0 bash build/build-app.sh and replace /Applications/Tunnel Monitor.app"
fi
if ! codesign --verify --deep --strict "${APP}" 2>/tmp/tm-codesign.txt; then
    cat /tmp/tm-codesign.txt
    fail_gate "Gate 5 codesign" "codesign --force --options runtime --timestamp --sign <Developer ID hash> \"${APP}\""
fi
archs="$(lipo -archs "${APP}/Contents/MacOS/TunnelMonitor" 2>/dev/null || echo "")"
case " ${archs} " in
    *" arm64 "*) pass_gate "Gate 5 app 1.4.0 signed arm64" ;;
    *) echo "archs=${archs}"; fail_gate "Gate 5 lipo" "Rebuild with swift --arch arm64 (universal is fine)." ;;
esac

# Gate 6
echo
echo "Gate 6: LaunchDaemon"
if ! launchctl print "system/${LABEL}" >/tmp/tm-launchctl.txt 2>&1; then
    cat /tmp/tm-launchctl.txt
    fail_gate "Gate 6 launchctl" "sudo launchctl bootstrap system /Library/LaunchDaemons/${LABEL}.plist"
fi
pass_gate "Gate 6 launchctl ${LABEL}"

# Gate 7
echo
echo "Gate 7: spoke SSH test"
if [[ "$(id -u)" -ne 0 ]]; then
    fail_gate "Gate 7 spoke-test" "sudo bash verify-1.4.0.sh"
fi
spoke_out="$(/usr/local/bin/tunnel-check --spoke-test 2>&1)" || {
    printf '%s\n' "${spoke_out}"
    echo "If SSH failed, authorize the monitor key once (you type the spoke password):"
    echo "  pub=\$(sudo cat /opt/tunnel-monitor/.ssh/id_ed25519.pub)"
    echo "  ssh root@<SPOKE_HOST> \"mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF \\\"\$pub\\\" ~/.ssh/authorized_keys || echo \\\"\$pub\\\" >> ~/.ssh/authorized_keys\""
    fail_gate "Gate 7 spoke-test" "sudo /usr/local/bin/tunnel-check --spoke-test"
}
printf '%s\n' "${spoke_out}"
policy_line="$(printf '%s\n' "${spoke_out}" | awk '/Policy state/ {print $3}')"
if [[ "${policy_line}" == "MISSING" ]]; then
    echo "NOTE: policy-state file is MISSING. The UDM check is not deployed yet. This is not an app failure."
    pass_gate "Gate 7 spoke-test (MISSING — UDM check not deployed)"
elif [[ "${policy_line}" =~ ^[0-9]+:(UP|DOWN)$ ]]; then
    pass_gate "Gate 7 spoke-test ${policy_line}"
else
    fail_gate "Gate 7 spoke-test" "Expected policy line N:UP, N:DOWN, or MISSING. Got: ${policy_line}"
fi

# Gate 8
echo
echo "Gate 8: state.json keys"
if ! launchctl kickstart -k "system/${LABEL}"; then
    fail_gate "Gate 8 kickstart" "sudo launchctl kickstart -k system/${LABEL}"
fi
sleep 8
if ! jq -e '.spoke_policy and (.remote_wan_observed != null or .remote_wan_observed == null) and .advisories' "${INSTALL_DIR}/state.json" >/dev/null 2>&1; then
    jq . "${INSTALL_DIR}/state.json" 2>/dev/null | head -80 || true
    fail_gate "Gate 8 state.json" "sudo launchctl kickstart -k system/${LABEL} and inspect /opt/tunnel-monitor/monitor.log"
fi
enabled="$(jq -r '.spoke_policy.enabled' "${INSTALL_DIR}/state.json")"
advisories="$(jq -c '.advisories' "${INSTALL_DIR}/state.json")"
observed="$(jq -r '.remote_wan_observed // empty' "${INSTALL_DIR}/state.json")"
configured="$(awk -F= '/^REMOTE_WAN_IP=/{gsub(/"/,"",$2); print $2}' "${INSTALL_DIR}/config.env")"
echo "spoke_policy.enabled=${enabled} advisories=${advisories} observed=${observed} configured_wan=${configured}"
if [[ "${enabled}" != "true" ]]; then
    fail_gate "Gate 8 enabled" "Set SPOKE_POLICY_ENABLED=\"true\" in /opt/tunnel-monitor/config.env and kick the daemon."
fi
if [[ -n "${observed}" && "${observed}" == "${configured}" && "${advisories}" != "[]" ]]; then
    echo "Advisories while observed WAN matches config:"
    jq -c '.advisories' "${INSTALL_DIR}/state.json"
    fail_gate "Gate 8 advisories" "If the only advisory is a stale WAN address, set REMOTE_WAN_IP to the observed value and kick the daemon."
fi
pass_gate "Gate 8 state.json"

# Gate 9 — simulated policy DOWN, then restore
echo
echo "Gate 9: simulated policy DOWN"
cfg="${INSTALL_DIR}/config.env"
orig_path="$(awk -F= '/^SPOKE_POLICY_STATE_PATH=/{gsub(/"/,"",$2); print $2}' "${cfg}")"
orig_path="${orig_path:-/data/tunnel-monitor/policy-state}"
host="$(awk -F= '/^SPOKE_HOST=/{gsub(/"/,"",$2); print $2}' "${cfg}")"
user="$(awk -F= '/^SPOKE_USER=/{gsub(/"/,"",$2); print $2}' "${cfg}")"
key="$(awk -F= '/^SPOKE_KEY=/{gsub(/"/,"",$2); print $2}' "${cfg}")"
user="${user:-root}"
key="${key:-/opt/tunnel-monitor/.ssh/id_ed25519}"
restore_path() {
    python3 - "${cfg}" "${orig_path}" <<'PY'
import re, sys
path, value = sys.argv[1], sys.argv[2]
text = open(path).read().splitlines()
out, seen = [], False
for line in text:
    if line.startswith("SPOKE_POLICY_STATE_PATH="):
        out.append('SPOKE_POLICY_STATE_PATH="%s"' % value)
        seen = True
    else:
        out.append(line)
if not seen:
    out.append('SPOKE_POLICY_STATE_PATH="%s"' % value)
open(path, "w").write("\n".join(out) + "\n")
PY
}
ssh_opts="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${INSTALL_DIR}/.ssh/known_hosts -i ${key}"
# shellcheck disable=SC2086
if ! ssh ${ssh_opts} "${user}@${host}" "printf '%s\n' '3:DOWN' > /tmp/tm-test-policy-state"; then
    fail_gate "Gate 9 plant DOWN" "Authorize the monitor key, then: ssh ${user}@${host} \"echo 3:DOWN > /tmp/tm-test-policy-state\""
fi
python3 - "${cfg}" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().splitlines()
out, seen = [], False
for line in text:
    if line.startswith("SPOKE_POLICY_STATE_PATH="):
        out.append('SPOKE_POLICY_STATE_PATH="/tmp/tm-test-policy-state"')
        seen = True
    else:
        out.append(line)
if not seen:
    out.append('SPOKE_POLICY_STATE_PATH="/tmp/tm-test-policy-state"')
open(path, "w").write("\n".join(out) + "\n")
PY
log_before="$(wc -l < "${INSTALL_DIR}/monitor.log" | tr -d ' ')"
launchctl kickstart -k "system/${LABEL}" || true
sleep 12
new_log="$(tail -n +"$((log_before + 1))" "${INSTALL_DIR}/monitor.log" 2>/dev/null || true)"
adv="$(jq -c '.advisories' "${INSTALL_DIR}/state.json" 2>/dev/null || echo '[]')"
email_hits="$(printf '%s\n' "${new_log}" | grep -c 'alert email sent' || true)"
banner_hits="$(printf '%s\n' "${new_log}" | grep -c 'advisory banner' || true)"
echo "advisories=${adv} email_hits=${email_hits} banner_hits=${banner_hits}"
restore_path
launchctl kickstart -k "system/${LABEL}" || true
if [[ "${adv}" != *SPOKE_POLICY_DOWN* ]]; then
    fail_gate "Gate 9 advisory" "Expected SPOKE_POLICY_DOWN. Path was restored. Inspect monitor.log and re-plant /tmp/tm-test-policy-state on the spoke."
fi
if [[ "${email_hits}" -ne 0 ]]; then
    fail_gate "Gate 9 no email" "An alert email was sent for a policy advisory. Advisories must not call send-email.sh."
fi
if [[ "${banner_hits}" -lt 1 ]]; then
    fail_gate "Gate 9 banner" "No advisory banner was logged. notify_advisory_transition should call notify.sh once."
fi
sleep 12
cleared="$(jq -c '.advisories' "${INSTALL_DIR}/state.json")"
echo "advisories after restore=${cleared}"
if [[ "${cleared}" == *SPOKE_POLICY_DOWN* ]]; then
    fail_gate "Gate 9 restore" "SPOKE_POLICY_DOWN still set after restoring SPOKE_POLICY_STATE_PATH. Kick the daemon again."
fi
pass_gate "Gate 9 simulated DOWN then clear"

# Gate 10 — strings introduced in this change, not historical docs.
echo
echo "Gate 10: sanitization"
hits="$(cd "${ROOT}" && git diff -U0 -- . ':(exclude)verify-1.4.0.sh' ':(exclude).build' \
    | grep -E '^\+' | grep -v '^\+\+\+' \
    | grep -E '192[.]168[.]|24[.]111[.]|75[.]72[.]|75[.]73[.]|onthewifi|Banana|Gam-and-Bee|mac[.]com' || true)"
if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" | head -40
    fail_gate "Gate 10 sanitization" "Remove site-specific strings from the public diff (placeholders only)."
fi
pass_gate "Gate 10 sanitization"

echo
echo "══════════════════════════════════════════════════════════"
echo "EXECUTION SUMMARY"
echo "──────────────────────────────────────────────────────────"
printf '%s\n' "${RESULTS}" | sed '/^$/d'
echo "──────────────────────────────────────────────────────────"
echo "Overall: PASSED"
echo "══════════════════════════════════════════════════════════"
exit 0
