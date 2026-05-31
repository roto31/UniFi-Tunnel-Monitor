#!/bin/bash
# Archive built artifacts into build/releases/<NN-vX.Y.Z>/ per datasets/bundle-manifest.json
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT_DIR}/datasets/bundle-manifest.json"
RELEASES_DIR="${ROOT_DIR}/build/releases"
DIST_DIR="${ROOT_DIR}/build/dist"

red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
archive-release.sh — copy dist artifacts into build/releases/<NN-vVERSION>/

USAGE
    bash build/archive-release.sh --version 1.1.0
    bash build/archive-release.sh --version 1.0.0 \
        --app "build/dist-public/Tunnel Monitor.app"
    bash build/archive-release.sh --version 1.1.0 --pkg build/dist/Tunnel-Monitor-1.1.0.pkg

Reads folder name (01-v1.0.0, …) from datasets/bundle-manifest.json.
EOF
}

VERSION=""
APP_PATH=""
PKG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help; exit 0 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --app) APP_PATH="${2:-}"; shift 2 ;;
        --pkg) PKG_PATH="${2:-}"; shift 2 ;;
        *) red "ERROR: unknown argument: $1"; exit 2 ;;
    esac
done

if [[ -z "${VERSION}" ]]; then
    red "ERROR: --version is required"
    exit 2
fi

if [[ ! -f "${MANIFEST}" ]] || ! command -v jq >/dev/null 2>&1; then
    red "ERROR: need ${MANIFEST} and jq"
    exit 3
fi

folder="$(jq -r --arg v "${VERSION}" \
    '.releases[] | select(.version == $v) | .folder' "${MANIFEST}" | head -1)"
sequence="$(jq -r --arg v "${VERSION}" \
    '.releases[] | select(.version == $v) | .sequence' "${MANIFEST}" | head -1)"
data_revision="$(jq -c --arg v "${VERSION}" \
    '.releases[] | select(.version == $v) | .dataRevision' "${MANIFEST}" | head -1)"

if [[ -z "${folder}" || "${folder}" == "null" ]]; then
    red "ERROR: version ${VERSION} not listed in ${MANIFEST}"
    exit 2
fi

if [[ -z "${APP_PATH}" ]]; then
    if [[ -d "${DIST_DIR}/Tunnel Monitor.app" ]]; then
        APP_PATH="${DIST_DIR}/Tunnel Monitor.app"
    elif [[ -d "${ROOT_DIR}/build/dist-public/Tunnel Monitor.app" ]]; then
        APP_PATH="${ROOT_DIR}/build/dist-public/Tunnel Monitor.app"
    fi
fi

if [[ -z "${PKG_PATH}" ]]; then
    candidate="${DIST_DIR}/Tunnel-Monitor-${VERSION}.pkg"
    if [[ -f "${candidate}" ]]; then
        PKG_PATH="${candidate}"
    fi
fi

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}/Contents/MacOS" ]]; then
    red "ERROR: .app not found; pass --app or build first"
    exit 1
fi

dest="${RELEASES_DIR}/${folder}"
mkdir -p "${dest}"

green "Archiving ${VERSION} → ${dest}"

rm -rf "${dest}/Tunnel Monitor.app"
ditto "${APP_PATH}" "${dest}/Tunnel Monitor.app"

if [[ -n "${PKG_PATH}" && -f "${PKG_PATH}" ]]; then
    cp -f "${PKG_PATH}" "${dest}/Tunnel-Monitor-${VERSION}.pkg"
    green "Archived pkg"
else
    yellow "WARN: no .pkg for ${VERSION} (run build-pkg.sh to add)"
fi

checksums="${dest}/CHECKSUMS.sha256"
: > "${checksums}"
(
    cd "${dest}"
    for artifact in "Tunnel Monitor.app" "Tunnel-Monitor-${VERSION}.pkg"; do
        if [[ -e "${artifact}" ]]; then
            if [[ -d "${artifact}" ]]; then
                ditto -c -k --sequesterRsrc --keepParent "${artifact}" "${dest}/.tmp-app.zip"
                shasum -a 256 ".tmp-app.zip" | awk -v n="${artifact}.zip" '{print $1 "  " n}' >> "${checksums}"
                rm -f "${dest}/.tmp-app.zip"
            else
                shasum -a 256 "${artifact}" >> "${checksums}"
            fi
        fi
    done
)

wizard_sha=""
wf="${dest}/Tunnel Monitor.app/Contents/Resources/wizard-fields.json"
if [[ -f "${wf}" ]]; then
    wizard_sha="$(shasum -a 256 "${wf}" | awk '{print $1}')"
fi

assets_sha=""
car="${dest}/Tunnel Monitor.app/Contents/Resources/Assets.car"
if [[ -f "${car}" ]]; then
    assets_sha="$(shasum -a 256 "${car}" | awk '{print $1}')"
fi

icon_sha=""
icns="${dest}/Tunnel Monitor.app/Contents/Resources/AppIcon.icns"
if [[ -f "${icns}" ]]; then
    icon_sha="$(shasum -a 256 "${icns}" | awk '{print $1}')"
fi

built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
jq -n \
    --arg version "${VERSION}" \
    --argjson sequence "${sequence}" \
    --arg folder "${folder}" \
    --arg builtAt "${built_at}" \
    --argjson dataRevision "${data_revision}" \
    --arg wizardSha "${wizard_sha}" \
    --arg assetsSha "${assets_sha}" \
    --arg iconSha "${icon_sha}" \
    '{
      version: $version,
      sequence: ($sequence | tonumber),
      folder: $folder,
      builtAt: $builtAt,
      dataRevision: $dataRevision,
      contentSha256: (
        {
          "wizard-fields.json": (if $wizardSha != "" then $wizardSha else null end),
          "Assets.car": (if $assetsSha != "" then $assetsSha else null end),
          "AppIcon.icns": (if $iconSha != "" then $iconSha else null end)
        }
      )
    }' > "${dest}/bundle-manifest.json"

green "Wrote ${dest}/bundle-manifest.json"
green "Wrote ${checksums}"
echo "  ${dest}"
