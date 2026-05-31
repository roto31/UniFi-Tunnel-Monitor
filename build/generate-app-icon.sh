#!/bin/bash
# Generate AppIcon.icns from a 1024×1024 master PNG (macOS 14–25 fallback).
# Liquid Glass: import Resources/AppIcon/Layers/*.svg in Icon Composer → AppIcon.icon
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="${ROOT_DIR}/app/TunnelMonitor/Resources"
MASTER="${RES_DIR}/AppIcon-1024.png"
ICONSET="${RES_DIR}/AppIcon.iconset"
ICNS="${RES_DIR}/AppIcon.icns"

if [[ ! -f "${MASTER}" ]]; then
    echo "ERROR: missing master icon ${MASTER}" >&2
    echo "Place a 1024×1024 PNG there (see AppIcon/README.md)." >&2
    exit 1
fi

if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
    echo "ERROR: sips and iconutil required (macOS)." >&2
    exit 1
fi

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

make_icon() {
    local size="$1"
    local name="$2"
    sips -z "${size}" "${size}" "${MASTER}" --out "${ICONSET}/${name}" >/dev/null
}

make_icon 16  "icon_16x16.png"
make_icon 32  "icon_16x16@2x.png"
make_icon 32  "icon_32x32.png"
make_icon 64  "icon_32x32@2x.png"
make_icon 128 "icon_128x128.png"
make_icon 256 "icon_128x128@2x.png"
make_icon 256 "icon_256x256.png"
make_icon 512 "icon_256x256@2x.png"
make_icon 512 "icon_512x512.png"
make_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "${ICONSET}" -o "${ICNS}"
rm -rf "${ICONSET}"
echo "Wrote ${ICNS}"
