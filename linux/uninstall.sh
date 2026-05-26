#!/bin/bash
# =============================================================================
# uninstall.sh — Linux tunnel monitor uninstall
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/tunnel-monitor"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_UNIT="tunnel-monitor.service"
TIMER_UNIT="tunnel-monitor.timer"
SYMLINK_DEST="/usr/local/bin/tunnel-check"

yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
uninstall.sh

USAGE
    sudo bash uninstall.sh
    sudo bash uninstall.sh --yes
    sudo bash uninstall.sh --keep
    sudo bash uninstall.sh --help
EOF
}

MODE="interactive"
case "${1:-}" in
    --help|-h) show_help; exit 0 ;;
    --yes)     MODE="yes" ;;
    --keep)    MODE="keep" ;;
    "")        MODE="interactive" ;;
    *)         red "ERROR: unknown flag: $1"; exit 1 ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    yellow "Re-executing under sudo..."
    exec sudo bash "${BASH_SOURCE[0]}" "$@"
fi

step "Stopping timer + service"
systemctl stop "${TIMER_UNIT}" 2>/dev/null || true
systemctl disable "${TIMER_UNIT}" 2>/dev/null || true
systemctl stop "${SERVICE_UNIT}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${TIMER_UNIT}" "${SYSTEMD_DIR}/${SERVICE_UNIT}"
systemctl daemon-reload || true
green "Units removed."

step "CLI symlink"
[[ -e "${SYMLINK_DEST}" ]] && rm -f "${SYMLINK_DEST}" && green "Removed ${SYMLINK_DEST}"

step "${INSTALL_DIR}"
if [[ ! -d "${INSTALL_DIR}" ]]; then
    green "Nothing to remove."
    exit 0
fi

remove_all() {
    rm -rf "${INSTALL_DIR}"
    green "Removed ${INSTALL_DIR}"
}

keep_config_state() {
    backup_dir="/tmp/tunnel-monitor.preserved.$(date +%s)"
    mkdir -p "${backup_dir}"
    [[ -f "${INSTALL_DIR}/config.env" ]] && cp -p "${INSTALL_DIR}/config.env" "${backup_dir}/"
    [[ -f "${INSTALL_DIR}/state.json" ]] && cp -p "${INSTALL_DIR}/state.json" "${backup_dir}/"
    rm -rf "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    chmod 0755 "${INSTALL_DIR}"
    [[ -f "${backup_dir}/config.env" ]] && cp -p "${backup_dir}/config.env" "${INSTALL_DIR}/config.env"
    [[ -f "${backup_dir}/state.json" ]] && cp -p "${backup_dir}/state.json" "${INSTALL_DIR}/state.json"
    rm -rf "${backup_dir}"
    green "Preserved config.env and state.json only."
}

case "${MODE}" in
    yes) remove_all ;;
    keep) keep_config_state ;;
    interactive)
        echo; bold "[1] Remove all  [2] Keep config.env + state.json  [3] Cancel"
        read -r -p "Choose: " c
        case "${c}" in
            1) remove_all ;;
            2) keep_config_state ;;
            3) yellow "Cancelled."; exit 0 ;;
            *) red "Invalid"; exit 1 ;;
        esac
        ;;
esac

green "Uninstall complete."
