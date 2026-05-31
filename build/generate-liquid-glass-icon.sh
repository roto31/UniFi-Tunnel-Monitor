#!/bin/bash
# Build AppIcon.icon (Liquid Glass) and compile with Xcode actool → Assets.car + AppIcon.icns
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${APP_SRC:-${ROOT_DIR}/mac/app/TunnelMonitor}"
RES_DIR="${APP_SRC}/Resources"
LAYERS_DIR="${RES_DIR}/AppIcon/Layers"
MASTER_PNG="${RES_DIR}/AppIcon-1024.png"
ICON_BUNDLE="${RES_DIR}/AppIcon.icon"
BUILD_OUT="${BUILD_OUT:-${ROOT_DIR}/build/icon-compile}"
ACTOOL="${ACTOOL:-$(xcrun --find actool 2>/dev/null || true)}"
ICTOOL_DEFAULT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ICTOOL="${ICTOOL:-${ICTOOL_DEFAULT}}"

# layered = rasterize SVG layers; composite = single master PNG (default, matches approved artwork)
ICON_MODE="${TM_ICON_MODE:-composite}"

red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

show_help() {
    cat <<'EOF'
generate-liquid-glass-icon.sh — AppIcon.icon + actool (macOS 26 Liquid Glass)

USAGE
    bash build/generate-liquid-glass-icon.sh
    TM_ICON_MODE=layered bash build/generate-liquid-glass-icon.sh

OUTPUT (into app/TunnelMonitor/Resources/)
    AppIcon.icon/     Icon Composer bundle (generated)
    Assets.car        Compiled Liquid Glass catalog
    AppIcon.icns      Legacy fallback (also from actool)

ENV
    APP_SRC           Swift package Resources parent
    TM_ICON_MODE      composite (default) | layered
    BUILD_OUT         actool compile staging dir
    SKIP_ICON_COMPILE 1 = only regenerate AppIcon.icon, skip actool

Requires Xcode 26+ actool and AppIcon-1024.png master artwork.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

if [[ ! -f "${MASTER_PNG}" ]]; then
    red "ERROR: missing master PNG: ${MASTER_PNG}"
    red "Run: bash build/generate-app-icon.sh (after placing AppIcon-1024.png)"
    exit 1
fi

if [[ -z "${ACTOOL}" || ! -x "${ACTOOL}" ]]; then
    red "ERROR: actool not found (install Xcode 26+)"
    exit 1
fi

rasterize_svg() {
    local svg_path="$1"
    local out_png="$2"
    if [[ ! -f "${svg_path}" ]]; then
        red "ERROR: missing SVG ${svg_path}"
        exit 1
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if ! qlmanage -t -s 1024 -o "${tmp_dir}" "${svg_path}" >/dev/null 2>&1; then
        red "ERROR: qlmanage failed for ${svg_path}"
        rm -rf "${tmp_dir}"
        exit 1
    fi
    local base_name
    base_name="$(basename "${svg_path}")"
    mv "${tmp_dir}/${base_name}.png" "${out_png}"
    rm -rf "${tmp_dir}"
}

write_manifest_composite() {
    local assets_dir="$1"
    cp "${MASTER_PNG}" "${assets_dir}/foreground.png"
    cat > "${ICON_BUNDLE}/icon.json" <<'JSON'
{
  "supported-platforms": { "squares": "shared" },
  "fill-specializations": [
    { "value": { "solid": "srgb:0.10588,0.24314,0.29020,1.00000" } },
    { "appearance": "dark", "value": { "solid": "srgb:0.03922,0.07843,0.11765,1.00000" } }
  ],
  "groups": [
    {
      "name": "Mascot",
      "lighting": "individual",
      "specular": true,
      "shadow": { "kind": "layer-color", "opacity": 0.45 },
      "translucency": { "enabled": true, "value": 0.12 },
      "blur-material": 0.2,
      "layers": [
        {
          "image-name": "foreground.png",
          "name": "foreground",
          "glass": true,
          "position": { "scale": 0.88, "translation-in-points": [0, 0] }
        }
      ]
    }
  ]
}
JSON
}

write_manifest_layered() {
    local assets_dir="$1"
    rasterize_svg "${LAYERS_DIR}/01-background.svg" "${assets_dir}/background.png"
    rasterize_svg "${LAYERS_DIR}/02-tunnel.svg" "${assets_dir}/tunnel.png"
    rasterize_svg "${LAYERS_DIR}/03-traffic-light.svg" "${assets_dir}/traffic-light.png"
    cat > "${ICON_BUNDLE}/icon.json" <<'JSON'
{
  "supported-platforms": { "squares": "shared" },
  "fill-specializations": [
    { "value": { "solid": "srgb:0.10588,0.24314,0.29020,1.00000" } },
    { "appearance": "dark", "value": { "solid": "srgb:0.03922,0.07843,0.11765,1.00000" } }
  ],
  "groups": [
    {
      "name": "Background",
      "lighting": "individual",
      "specular": true,
      "shadow": { "kind": "neutral", "opacity": 0.2 },
      "blur-material": 0.35,
      "layers": [
        {
          "image-name": "background.png",
          "name": "background",
          "glass": true,
          "opacity": 0.9
        }
      ]
    },
    {
      "name": "Tunnel",
      "lighting": "individual",
      "specular": true,
      "shadow": { "kind": "layer-color", "opacity": 0.35 },
      "layers": [
        {
          "image-name": "tunnel.png",
          "name": "tunnel",
          "glass": true,
          "position": { "scale": 1.0, "translation-in-points": [0, 0] }
        }
      ]
    },
    {
      "name": "TrafficLight",
      "lighting": "individual",
      "specular": true,
      "shadow": { "kind": "layer-color", "opacity": 0.5 },
      "translucency": { "enabled": true, "value": 0.1 },
      "layers": [
        {
          "image-name": "traffic-light.png",
          "name": "traffic-light",
          "glass": true,
          "position": { "scale": 1.0, "translation-in-points": [0, 0] }
        }
      ]
    }
  ]
}
JSON
}

green "==> Generate AppIcon.icon (${ICON_MODE})"
rm -rf "${ICON_BUNDLE}"
mkdir -p "${ICON_BUNDLE}/Assets"

case "${ICON_MODE}" in
    composite)
        write_manifest_composite "${ICON_BUNDLE}/Assets"
        ;;
    layered)
        write_manifest_layered "${ICON_BUNDLE}/Assets"
        ;;
    *)
        red "ERROR: TM_ICON_MODE must be composite or layered (got: ${ICON_MODE})"
        exit 1
        ;;
esac

if [[ "${SKIP_ICON_COMPILE:-0}" == "1" ]]; then
    yellow "SKIP_ICON_COMPILE=1 — left bundle at ${ICON_BUNDLE}"
    exit 0
fi

green "==> actool compile → Assets.car + AppIcon.icns"
rm -rf "${BUILD_OUT}"
mkdir -p "${BUILD_OUT}"

if ! "${ACTOOL}" "${ICON_BUNDLE}" \
    --compile "${BUILD_OUT}" \
    --app-icon AppIcon \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "${BUILD_OUT}/partial.plist" \
    --output-format human-readable-text; then
    red "ERROR: actool failed"
    exit 1
fi

if [[ ! -f "${BUILD_OUT}/Assets.car" ]]; then
    red "ERROR: actool did not produce Assets.car"
    exit 1
fi

cp "${BUILD_OUT}/Assets.car" "${RES_DIR}/Assets.car"
if [[ -f "${BUILD_OUT}/AppIcon.icns" ]]; then
    cp "${BUILD_OUT}/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
    green "Wrote ${RES_DIR}/AppIcon.icns (actool legacy + Tahoe)"
else
    yellow "WARN: actool did not emit AppIcon.icns; keeping existing if any"
fi
green "Wrote ${RES_DIR}/Assets.car"

if [[ -x "${ICTOOL}" && -d "${ICON_BUNDLE}" ]]; then
    preview="${BUILD_OUT}/AppIcon-macOS-default.png"
    if "${ICTOOL}" "${ICON_BUNDLE}" \
        --export-image \
        --output-file "${preview}" \
        --platform macOS \
        --rendition Default \
        --width 512 \
        --height 512 \
        --scale 2 2>/dev/null; then
        green "Preview: ${preview} (ictool)"
    fi
fi

green "Liquid Glass icon ready. Rebuild app: bash build/build-app.sh"
