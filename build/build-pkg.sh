#!/bin/bash
# =============================================================================
# build-pkg.sh — assemble the distributable Tunnel-Monitor.pkg
# =============================================================================
# Produces:  build/dist/Tunnel-Monitor-<VERSION>.pkg
#
# Layout staged into the .pkg:
#   /Applications/Tunnel Monitor.app          ← built by build-app.sh
#   /opt/tunnel-monitor/*                     ← from payload/opt/tunnel-monitor/
#   /Library/LaunchDaemons/com.ruter.tunnel-monitor.plist
#   /Library/Application Support/Tunnel Monitor/
#       payload/SwiftBar/tunnel-monitor.30s.sh   (deployed to user by postinstall)
#       install.sh, uninstall.sh, verify.sh      (for manual ops)
#
# Env vars:
#   VERSION                       Version stamped into the pkg + app (default: 1.0.0)
#   DEVELOPER_ID_APPLICATION      Apple Developer ID for codesigning the .app
#   DEVELOPER_ID_INSTALLER        Apple Developer ID for signing the .pkg
#                                 "Developer ID Installer: Name (TEAMID)"
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
#                                 If all three set (and no ASC .p8), notarize + staple.
#   ASC_KEY_P8_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#                                 Preferred notarization (App Store Connect API key).
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${BUILD_DIR}/dist"
STAGE_DIR="${BUILD_DIR}/.stage"
SCRIPTS_SRC="${BUILD_DIR}/scripts"
SCRIPTS_STAGE="${BUILD_DIR}/.scripts"
RESOURCES_DIR="${BUILD_DIR}/Resources"

if [[ -d "${ROOT_DIR}/mac/payload" ]]; then
    PAYLOAD_DIR="${ROOT_DIR}/mac/payload"
    LAUNCHDAEMON_PLIST="com.example.tunnel-monitor.plist"
    SSH_STATE_SCRIPT="ssh-router-state.sh"
    MAINT_SCRIPTS_DIR="${ROOT_DIR}/mac"
elif [[ -d "${ROOT_DIR}/payload" ]]; then
    PAYLOAD_DIR="${ROOT_DIR}/payload"
    LAUNCHDAEMON_PLIST="com.ruter.tunnel-monitor.plist"
    SSH_STATE_SCRIPT="ssh-udr7-state.sh"
    MAINT_SCRIPTS_DIR="${ROOT_DIR}"
else
    red "ERROR: no payload directory (expected mac/payload or payload/)"
    exit 2
fi

APP_BUNDLE="${DIST_DIR}/Tunnel Monitor.app"
if [[ ! -d "${APP_BUNDLE}" && -d "${BUILD_DIR}/dist-public/Tunnel Monitor.app" ]]; then
    APP_BUNDLE="${BUILD_DIR}/dist-public/Tunnel Monitor.app"
fi

VERSION="${VERSION:-1.0.0}"
PKG_IDENTIFIER="com.tunnel.monitor.pkg"
PKG_NAME="Tunnel-Monitor-${VERSION}.pkg"
COMPONENT_PKG="${BUILD_DIR}/.component.pkg"
DIST_XML="${BUILD_DIR}/distribution.xml"
FINAL_PKG="${DIST_DIR}/${PKG_NAME}"

bold()  { printf '\033[1m%s\033[0m\n'    "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
build-pkg.sh — assemble Tunnel-Monitor-<VERSION>.pkg

USAGE
    bash build/build-pkg.sh
    VERSION=1.2.3 bash build/build-pkg.sh
    DEVELOPER_ID_APPLICATION="..." DEVELOPER_ID_INSTALLER="..." \
        bash build/build-pkg.sh

OUTPUT
    build/dist/Tunnel-Monitor-<VERSION>.pkg
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help; exit 0
fi

if [[ "$(uname)" != "Darwin" ]]; then
    red "ERROR: build-pkg.sh must run on macOS."
    exit 3
fi

for c in pkgbuild productbuild codesign; do
    if ! command -v "$c" >/dev/null 2>&1; then
        red "ERROR: missing required command: $c"
        exit 3
    fi
done

# -----------------------------------------------------------------------------
# Step 1 — build the .app if missing or stale
# -----------------------------------------------------------------------------

step "Phase 1 — ensure .app is built"
bundled_ver=""
if [[ -f "${APP_BUNDLE}/Contents/Info.plist" ]]; then
    bundled_ver="$(plutil -extract CFBundleShortVersionString raw "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -d "${APP_BUNDLE}" && "${bundled_ver}" != "${VERSION}" ]]; then
    yellow "Existing .app is version ${bundled_ver:-unknown}; need ${VERSION} — rebuilding."
    rm -rf "${APP_BUNDLE}"
fi
if [[ ! -d "${APP_BUNDLE}" ]]; then
    yellow ".app bundle missing — running build-app.sh..."
    VERSION="${VERSION}" bash "${BUILD_DIR}/build-app.sh"
fi
if [[ ! -d "${APP_BUNDLE}" ]]; then
    red "ERROR: ${APP_BUNDLE} still missing after build-app.sh"
    exit 1
fi
green "App ready: ${APP_BUNDLE} (${VERSION})"

# -----------------------------------------------------------------------------
# Step 2 — stage payload root
# -----------------------------------------------------------------------------

step "Phase 2 — stage payload root"
rm -rf "${STAGE_DIR}" "${SCRIPTS_STAGE}"
mkdir -p "${STAGE_DIR}/Applications"
mkdir -p "${STAGE_DIR}/opt/tunnel-monitor"
mkdir -p "${STAGE_DIR}/Library/LaunchDaemons"
mkdir -p "${STAGE_DIR}/Library/Application Support/Tunnel Monitor/payload/SwiftBar"
mkdir -p "${STAGE_DIR}/Library/Application Support/Tunnel Monitor/scripts"

# App
ditto "${APP_BUNDLE}" "${STAGE_DIR}/Applications/Tunnel Monitor.app"

# Scripts → /opt/tunnel-monitor (everything except config.env)
for f in monitor.sh notify.sh send-email.sh "${SSH_STATE_SCRIPT}" tunnel-check config.env.template; do
    src="${PAYLOAD_DIR}/opt/tunnel-monitor/${f}"
    if [[ ! -f "${src}" ]]; then
        red "ERROR: payload missing: ${src}"
        exit 1
    fi
    cp "${src}" "${STAGE_DIR}/opt/tunnel-monitor/${f}"
done

# LaunchDaemon plist
cp "${PAYLOAD_DIR}/LaunchDaemons/${LAUNCHDAEMON_PLIST}" \
   "${STAGE_DIR}/Library/LaunchDaemons/${LAUNCHDAEMON_PLIST}"

# SwiftBar plugin (deployed to user dir by postinstall)
cp "${PAYLOAD_DIR}/SwiftBar/tunnel-monitor.30s.sh" \
   "${STAGE_DIR}/Library/Application Support/Tunnel Monitor/payload/SwiftBar/tunnel-monitor.30s.sh"

# Maintenance scripts for power users
for f in install.sh uninstall.sh verify.sh; do
    if [[ -f "${MAINT_SCRIPTS_DIR}/${f}" ]]; then
        cp "${MAINT_SCRIPTS_DIR}/${f}" "${STAGE_DIR}/Library/Application Support/Tunnel Monitor/scripts/${f}"
    fi
done

# Strip macOS resource forks / extended attributes so they don't pollute the BOM.
xattr -cr "${STAGE_DIR}" 2>/dev/null || true
find "${STAGE_DIR}" -name '._*' -delete 2>/dev/null || true

green "Staged ${STAGE_DIR}"

# -----------------------------------------------------------------------------
# Step 3 — stage installer scripts (preinstall / postinstall)
# -----------------------------------------------------------------------------

step "Phase 3 — stage installer scripts"
mkdir -p "${SCRIPTS_STAGE}"
for s in preinstall postinstall; do
    if [[ -f "${SCRIPTS_SRC}/${s}" ]]; then
        cp "${SCRIPTS_SRC}/${s}" "${SCRIPTS_STAGE}/${s}"
        chmod 0755 "${SCRIPTS_STAGE}/${s}"
    fi
done
green "Scripts staged."

# -----------------------------------------------------------------------------
# Step 4 — build component pkg
# -----------------------------------------------------------------------------

step "Phase 4 — pkgbuild component"
pkgbuild \
    --root "${STAGE_DIR}" \
    --identifier "${PKG_IDENTIFIER}" \
    --version "${VERSION}" \
    --install-location "/" \
    --scripts "${SCRIPTS_STAGE}" \
    --ownership recommended \
    "${COMPONENT_PKG}"
green "Component pkg: ${COMPONENT_PKG}"

# -----------------------------------------------------------------------------
# Step 5 — render distribution.xml with VERSION
# -----------------------------------------------------------------------------

step "Phase 5 — render distribution.xml"
RENDERED_DIST="${BUILD_DIR}/.distribution.rendered.xml"
sed -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__COMPONENT_PKG__|$(basename "${COMPONENT_PKG}")|g" \
    "${DIST_XML}" > "${RENDERED_DIST}"
green "Rendered distribution.xml"

# -----------------------------------------------------------------------------
# Step 6 — productbuild final pkg
# -----------------------------------------------------------------------------

step "Phase 6 — productbuild"
mkdir -p "${DIST_DIR}"
PB_ARGS=(
    --distribution "${RENDERED_DIST}"
    --package-path "$(dirname "${COMPONENT_PKG}")"
    --resources    "${RESOURCES_DIR}"
)
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
    PB_ARGS+=(--sign "${DEVELOPER_ID_INSTALLER}")
fi
productbuild "${PB_ARGS[@]}" "${FINAL_PKG}"
green "Built ${FINAL_PKG}"

# -----------------------------------------------------------------------------
# Step 7 — optional notarization + staple
# -----------------------------------------------------------------------------

NOTARIZED=0
if [[ -z "${DEVELOPER_ID_INSTALLER:-}" ]]; then
    yellow "Skipping notarization (pkg is unsigned — set DEVELOPER_ID_INSTALLER)."
elif [[ -n "${ASC_KEY_P8_PATH:-}" && -f "${ASC_KEY_P8_PATH}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    step "Phase 7 — notarize (App Store Connect API key)"
    if ! command -v xcrun >/dev/null 2>&1; then
        red "ERROR: xcrun missing — cannot notarize."
        exit 3
    fi
    yellow "Submitting to Apple notary service (this can take several minutes)..."
    xcrun notarytool submit "${FINAL_PKG}" \
        --key "${ASC_KEY_P8_PATH}" \
        --key-id "${ASC_KEY_ID}" \
        --issuer "${ASC_ISSUER_ID}" \
        --wait
    NOTARIZED=1
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    step "Phase 7 — notarize (Apple ID)"
    if ! command -v xcrun >/dev/null 2>&1; then
        red "ERROR: xcrun missing — cannot notarize."
        exit 3
    fi
    yellow "Submitting to Apple notary service (this can take several minutes)..."
    xcrun notarytool submit "${FINAL_PKG}" \
        --apple-id     "${APPLE_ID}" \
        --team-id      "${APPLE_TEAM_ID}" \
        --password     "${APPLE_APP_SPECIFIC_PASSWORD}" \
        --wait
    NOTARIZED=1
else
    yellow "Skipping notarization (set ASC_KEY_P8_PATH + ASC_KEY_ID + ASC_ISSUER_ID, or Apple ID + app-specific password)."
fi

if [[ "${NOTARIZED}" -eq 1 ]]; then
    step "Phase 8 — staple"
    xcrun stapler staple "${FINAL_PKG}"
    xcrun stapler validate "${FINAL_PKG}"
    green "Notarized and stapled."
fi

# -----------------------------------------------------------------------------
# Cleanup intermediates
# -----------------------------------------------------------------------------
rm -rf "${STAGE_DIR}" "${SCRIPTS_STAGE}" "${COMPONENT_PKG}" "${RENDERED_DIST}"

if [[ "${ARCHIVE_RELEASE:-1}" == "1" ]] && [[ -x "${ROOT_DIR}/build/archive-release.sh" ]]; then
    step "Phase 9 — archive to build/releases/"
    bash "${ROOT_DIR}/build/archive-release.sh" \
        --version "${VERSION}" \
        --app "${APP_BUNDLE}" \
        --pkg "${FINAL_PKG}" || \
        yellow "WARN: archive-release.sh failed (pkg still at ${FINAL_PKG})"
fi

bold ""
bold "PKG ready: ${FINAL_PKG}"
bold "Install with:  sudo installer -pkg \"${FINAL_PKG}\" -target /"
exit 0
