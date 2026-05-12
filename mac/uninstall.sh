#!/bin/bash
# =============================================================================
# uninstall.sh — clean reversal of install.sh
# =============================================================================
# Stops the daemon, removes the plist, removes /opt/tunnel-monitor (with
# interactive confirmation for config.env / state.json), removes the symlink,
# and removes the SwiftBar plugin.
#
#   sudo bash uninstall.sh           # interactive, asks before destroying
#   sudo bash uninstall.sh --yes     # non-interactive, removes everything
#   sudo bash uninstall.sh --keep    # non-interactive, keeps config + state
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/tunnel-monitor"
LAUNCHD_LABEL="com.example.tunnel-monitor"
PLIST_DEST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
SYMLINK_DEST="/usr/local/bin/tunnel-check"

bold()  { printf '\033[1m%s\033[0m\n'    "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
uninstall.sh — reverse install.sh cleanly

USAGE
    sudo bash uninstall.sh           # interactive
    sudo bash uninstall.sh --yes     # remove everything, no prompts
    sudo bash uninstall.sh --keep    # keep config.env + state.json
    sudo bash uninstall.sh --help
EOF
}

MODE="interactive"
case "${1:-}" in
    --help|-h) show_help; exit 0 ;;
    --yes)     MODE="yes" ;;
    --keep)    MODE="keep" ;;
    "")        MODE="interactive" ;;
    *)         red "ERROR: unknown flag: $1"; show_help >&2; exit 1 ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    yellow "Re-executing under sudo..."
    exec sudo bash "${BASH_SOURCE[0]}" "$@"
fi

INVOKER_USER="${SUDO_USER:-}"
if [[ -z "${INVOKER_USER}" || "${INVOKER_USER}" == "root" ]]; then
    INVOKER_USER="$(stat -f "%Su" /dev/console 2>/dev/null || echo "")"
fi
INVOKER_HOME=""
[[ -n "${INVOKER_USER}" && "${INVOKER_USER}" != "root" ]] && INVOKER_HOME="$(eval echo "~${INVOKER_USER}")"

# -----------------------------------------------------------------------------
# Stop and unload the daemon
# -----------------------------------------------------------------------------

step "Stopping LaunchDaemon"
if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    launchctl bootout system "${PLIST_DEST}" 2>/dev/null || true
    green "Daemon booted out."
else
    yellow "Daemon not loaded — skipping."
fi

if [[ -f "${PLIST_DEST}" ]]; then
    rm -f "${PLIST_DEST}"
    green "Removed ${PLIST_DEST}"
fi

# -----------------------------------------------------------------------------
# Remove symlink
# -----------------------------------------------------------------------------

step "Removing CLI symlink"
if [[ -L "${SYMLINK_DEST}" || -e "${SYMLINK_DEST}" ]]; then
    rm -f "${SYMLINK_DEST}"
    green "Removed ${SYMLINK_DEST}"
else
    yellow "${SYMLINK_DEST} not present — skipping."
fi

# -----------------------------------------------------------------------------
# Remove SwiftBar plugin
# -----------------------------------------------------------------------------

step "Removing SwiftBar plugin"
PLUGIN_REMOVED=false
if [[ -n "${INVOKER_USER}" && "${INVOKER_USER}" != "root" && -n "${INVOKER_HOME}" ]]; then
    PLUGIN_DIR=""
    if PD="$(sudo -u "${INVOKER_USER}" defaults read com.ainvyu.SwiftBar PluginDirectory 2>/dev/null)"; then
        PLUGIN_DIR="${PD/#\~/${INVOKER_HOME}}"
    fi
    [[ -z "${PLUGIN_DIR}" ]] && PLUGIN_DIR="${INVOKER_HOME}/Library/Application Support/SwiftBar/Plugins"

    PLUGIN_FILE="${PLUGIN_DIR}/tunnel-monitor.30s.sh"
    if [[ -f "${PLUGIN_FILE}" ]]; then
        rm -f "${PLUGIN_FILE}"
        green "Removed ${PLUGIN_FILE}"
        PLUGIN_REMOVED=true
    fi
fi
[[ "${PLUGIN_REMOVED}" == "false" ]] && yellow "No SwiftBar plugin file found to remove."

# -----------------------------------------------------------------------------
# Remove install dir (with config/state guard)
# -----------------------------------------------------------------------------

step "Removing ${INSTALL_DIR}"

if [[ ! -d "${INSTALL_DIR}" ]]; then
    yellow "${INSTALL_DIR} not present — nothing to remove."
    green "Uninstall complete."
    exit 0
fi

remove_all() {
    rm -rf "${INSTALL_DIR}"
    green "Removed ${INSTALL_DIR} entirely."
}

keep_config_state() {
    bold "Keeping config.env and state.json. Removing everything else..."
    local backup_dir="/tmp/tunnel-monitor.preserved.$(date +%s)"
    mkdir -p "${backup_dir}"
    [[ -f "${INSTALL_DIR}/config.env" ]] && cp -p "${INSTALL_DIR}/config.env" "${backup_dir}/"
    [[ -f "${INSTALL_DIR}/state.json" ]] && cp -p "${INSTALL_DIR}/state.json" "${backup_dir}/"
    rm -rf "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    chmod 0755 "${INSTALL_DIR}"
    chown root:wheel "${INSTALL_DIR}"
    [[ -f "${backup_dir}/config.env" ]] && cp -p "${backup_dir}/config.env" "${INSTALL_DIR}/config.env"
    [[ -f "${backup_dir}/state.json" ]] && cp -p "${backup_dir}/state.json" "${INSTALL_DIR}/state.json"
    rm -rf "${backup_dir}"
    green "Preserved config.env and state.json under ${INSTALL_DIR}."
}

case "${MODE}" in
    yes)
        remove_all
        ;;
    keep)
        keep_config_state
        ;;
    interactive)
        echo
        bold "Interactive mode — choose what to remove:"
        echo "  [1] Remove everything (including config.env and state.json)"
        echo "  [2] Keep config.env and state.json (remove the rest)"
        echo "  [3] Cancel"
        read -r -p "Choose [1-3]: " choice
        case "${choice}" in
            1) remove_all ;;
            2) keep_config_state ;;
            3) yellow "Cancelled."; exit 0 ;;
            *) red "Invalid choice — cancelling."; exit 1 ;;
        esac
        ;;
esac

green "Uninstall complete."
exit 0
