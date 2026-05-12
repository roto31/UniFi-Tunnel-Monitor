#!/bin/bash
# =============================================================================
# build-app.sh — build the sanitized Public menu bar app
# =============================================================================
# Runs the repo-root packager with APP_SRC pointing at this copy so the
# bundle keeps the sanitized Info.plist + wizard-fields.json. Output goes
# to ../../../build/dist-public/ to avoid colliding with the private build.
#
# Output: <repo>/build/dist-public/Tunnel Monitor.app
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
export APP_SRC="${SCRIPT_DIR}/TunnelMonitor"
export DIST_DIR="${REPO_ROOT}/build/dist-public"

exec bash "${REPO_ROOT}/build/build-app.sh" "$@"
