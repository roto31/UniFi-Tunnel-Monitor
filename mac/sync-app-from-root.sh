#!/bin/bash
# =============================================================================
# sync-app-from-root.sh — refresh Public/mac/app Swift sources from the
# private repo-root app. Preserves sanitized Resources/ (Info.plist + wizard).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SRC="${REPO_ROOT}/app/TunnelMonitor"
DST="${SCRIPT_DIR}/app/TunnelMonitor"

mkdir -p "${DST}/Sources/TunnelMonitor"
cp -f "${SRC}/Package.swift" "${DST}/"
cp -f "${SRC}/Sources/TunnelMonitor/"*.swift "${DST}/Sources/TunnelMonitor/"
echo "Synced Swift sources: ${SRC} -> ${DST}"
echo "Sanitized Resources/ left unchanged under ${DST}/Resources/"
