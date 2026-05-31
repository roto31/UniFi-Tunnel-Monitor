#!/bin/bash
# =============================================================================
# build-app.sh — compile the SwiftUI menu bar app into Tunnel Monitor.app
# =============================================================================
# Produces:  build/dist/Tunnel Monitor.app
#
# Env vars:
#   VERSION                       Marketing + bundle version  (default: 1.0.0)
#   DEVELOPER_ID_APPLICATION      "Developer ID Application: Your Name (TEAMID)"
#                                 If set, the .app is codesigned with hardened
#                                 runtime + timestamp. If unset, adhoc-signs the
#                                 bundle (needed for launch from /Applications).
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${APP_SRC:-${ROOT_DIR}/mac/app/TunnelMonitor}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/build/dist}"
APP_BUNDLE="${DIST_DIR}/Tunnel Monitor.app"
BIN_NAME="TunnelMonitor"
VERSION="${VERSION:-1.0.0}"

bold()  { printf '\033[1m%s\033[0m\n'    "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
build-app.sh — build Tunnel Monitor.app

USAGE
    bash build/build-app.sh
    VERSION=1.2.3 bash build/build-app.sh
    DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)" \
        bash build/build-app.sh

OUTPUT
    build/dist/Tunnel Monitor.app

ENV
    APP_SRC   Path to the Swift package (default: <repo>/app/TunnelMonitor).
              The Public build sets this to mac/app/TunnelMonitor.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help; exit 0
fi

if [[ "$(uname)" != "Darwin" ]]; then
    red "ERROR: build-app.sh must run on macOS."
    exit 3
fi

if [[ "${TM_SKIP_LIQUID_GLASS:-0}" != "1" ]]; then
    step "Phase 0b — Liquid Glass app icon (actool)"
    if bash "${ROOT_DIR}/build/generate-liquid-glass-icon.sh"; then
        green "Liquid Glass icon compiled"
    else
        yellow "WARN: Liquid Glass icon step failed; using existing AppIcon.icns if present"
    fi
fi

if ! command -v swift >/dev/null 2>&1; then
    red "ERROR: swift toolchain not found. Install Xcode command-line tools:"
    red "       xcode-select --install"
    exit 3
fi

if ! command -v swift >/dev/null 2>&1; then
    red "ERROR: swift toolchain not found. Install Xcode command-line tools:"
    red "       xcode-select --install"
    exit 3
fi

XCODE_PROJECT_DIR="${ROOT_DIR}/app/TunnelMonitorXcode"
XCODE_PROJECT="${XCODE_PROJECT_DIR}/TunnelMonitor.xcodeproj"
USE_XCODE=0

if [[ -f "${XCODE_PROJECT_DIR}/project.yml" ]] && command -v xcodegen >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
    step "Phase 0 — Xcode project (app + widget)"
    (
        cd "${XCODE_PROJECT_DIR}"
        xcodegen generate
    )
    if [[ -d "${XCODE_PROJECT}" ]]; then
        USE_XCODE=1
    fi
fi

if [[ "${USE_XCODE}" -eq 1 ]]; then
    step "Phase 1 — xcodebuild (Release, universal)"
    mkdir -p "${DIST_DIR}"
    BUILD_ROOT="${ROOT_DIR}/build/xcode-build"
    rm -rf "${BUILD_ROOT}"
    xcodebuild \
        -project "${XCODE_PROJECT}" \
        -scheme TunnelMonitor \
        -configuration Release \
        -derivedDataPath "${BUILD_ROOT}/DerivedData" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="${VERSION}" \
        CURRENT_PROJECT_VERSION="${VERSION}" \
        build
    XCODE_APP="$(find "${BUILD_ROOT}/DerivedData/Build/Products/Release" -maxdepth 1 -name 'Tunnel Monitor.app' -print -quit)"
    if [[ -z "${XCODE_APP}" || ! -d "${XCODE_APP}" ]]; then
        red "ERROR: xcodebuild did not produce Tunnel Monitor.app"
        exit 1
    fi
    rm -rf "${APP_BUNDLE}"
    cp -R "${XCODE_APP}" "${APP_BUNDLE}"
    if [[ -f "${APP_SRC}/Resources/AppIcon.icns" ]]; then
        cp "${APP_SRC}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    fi
    if [[ -f "${APP_SRC}/Resources/Assets.car" ]]; then
        cp "${APP_SRC}/Resources/Assets.car" "${APP_BUNDLE}/Contents/Resources/Assets.car"
        green "Bundled Liquid Glass Assets.car (xcodebuild)"
    fi
    green "Built ${APP_BUNDLE} (with widget extension)"
else
    yellow "XcodeGen/xcodebuild unavailable — building SPM app without widget."
    step "Phase 1 — swift build (release, universal)"
    mkdir -p "${DIST_DIR}"
    (
        cd "${APP_SRC}"
        swift build -c release \
            --arch arm64 --arch x86_64 \
            --disable-sandbox
    )
    BIN_PATH="$(cd "${APP_SRC}" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
    if [[ ! -x "${BIN_PATH}/${BIN_NAME}" ]]; then
        red "ERROR: built binary not found at ${BIN_PATH}/${BIN_NAME}"
        exit 1
    fi
    green "Built ${BIN_PATH}/${BIN_NAME}"

    step "Phase 2 — assemble .app bundle"
    rm -rf "${APP_BUNDLE}"
    mkdir -p "${APP_BUNDLE}/Contents/MacOS"
    mkdir -p "${APP_BUNDLE}/Contents/Resources"

    cp "${BIN_PATH}/${BIN_NAME}" "${APP_BUNDLE}/Contents/MacOS/${BIN_NAME}"
    chmod 0755 "${APP_BUNDLE}/Contents/MacOS/${BIN_NAME}"

    sed -e "s|__VERSION__|${VERSION}|g" \
        "${APP_SRC}/Resources/Info.plist" \
        > "${APP_BUNDLE}/Contents/Info.plist"

    if [[ -f "${APP_SRC}/Resources/AppIcon.icns" ]]; then
        cp "${APP_SRC}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    fi
    if [[ -f "${APP_SRC}/Resources/Assets.car" ]]; then
        cp "${APP_SRC}/Resources/Assets.car" "${APP_BUNDLE}/Contents/Resources/Assets.car"
        green "Bundled Liquid Glass Assets.car"
    fi

    shopt -s nullglob
    for res in "${APP_SRC}/Resources/"*.json; do
        cp "${res}" "${APP_BUNDLE}/Contents/Resources/"
        green "Bundled Resources/$(basename "${res}")"
    done
    shopt -u nullglob

    printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"
    green "Assembled ${APP_BUNDLE}"
fi

step "Phase 3 — codesign"
ENTITLEMENTS="${ROOT_DIR}/build/TunnelMonitor.entitlements"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    SIGN_ARGS=(--force --options runtime --timestamp \
        --sign "${DEVELOPER_ID_APPLICATION}")
    if [[ -f "${ENTITLEMENTS}" ]]; then
        SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
    fi
    if [[ -d "${APP_BUNDLE}/Contents/PlugIns" ]]; then
        find "${APP_BUNDLE}/Contents/PlugIns" -name '*.appex' -print0 | while IFS= read -r -d '' appex; do
            WIDGET_ENT="${ROOT_DIR}/app/TunnelMonitorXcode/TunnelMonitorWidget/TunnelMonitorWidget.entitlements"
            if [[ -f "${WIDGET_ENT}" ]]; then
                codesign "${SIGN_ARGS[@]}" --entitlements "${WIDGET_ENT}" "${appex}"
            else
                codesign "${SIGN_ARGS[@]}" "${appex}"
            fi
        done
    fi
    codesign "${SIGN_ARGS[@]}" "${APP_BUNDLE}/Contents/MacOS/"*
    codesign "${SIGN_ARGS[@]}" "${APP_BUNDLE}"
    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
    green "Codesigned with: ${DEVELOPER_ID_APPLICATION}"
else
    yellow "DEVELOPER_ID_APPLICATION not set — adhoc-signing bundle (required for /Applications launch)."
    ADHOC_ARGS=(--force --deep --sign -)
    if [[ -f "${ENTITLEMENTS}" ]]; then
        ADHOC_ARGS+=(--entitlements "${ENTITLEMENTS}")
    fi
    codesign "${ADHOC_ARGS[@]}" "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    green "Adhoc-signed ${APP_BUNDLE}"
fi

if [[ "${ARCHIVE_RELEASE:-1}" == "1" ]] && [[ -x "${ROOT_DIR}/build/archive-release.sh" ]]; then
    step "Phase 4 — archive to build/releases/"
    bash "${ROOT_DIR}/build/archive-release.sh" --version "${VERSION}" --app "${APP_BUNDLE}" || \
        yellow "WARN: archive-release.sh failed (dist artifact still at ${APP_BUNDLE})"
fi

bold "Done."
echo "  ${APP_BUNDLE}"
exit 0
