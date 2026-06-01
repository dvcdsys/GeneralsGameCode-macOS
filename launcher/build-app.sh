#!/usr/bin/env bash
#
# build-app.sh — compile the SwiftUI launcher and wrap it into a macOS .app
# bundle (arm64, ad-hoc signed). Prints the path to the produced .app.
#
# Usage:  launcher/build-app.sh
# Env:    OUT_DIR  where to put the .app   (default: <repo>/dist)

set -euo pipefail

LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${LAUNCHER_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"

APP_NAME="GeneralsZH Launcher"
APP="${OUT_DIR}/${APP_NAME}.app"
EXE_NAME="GeneralsZHLauncher"

log() { printf '\033[1;36m[launcher]\033[0m %s\n' "$*"; }

log "building (release, arm64)…"
swift build -c release --arch arm64 --package-path "${LAUNCHER_DIR}"
BIN_DIR="$(swift build -c release --arch arm64 --package-path "${LAUNCHER_DIR}" --show-bin-path)"
EXE="${BIN_DIR}/${EXE_NAME}"
[ -x "${EXE}" ] || { echo "build produced no executable at ${EXE}" >&2; exit 1; }

log "assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${EXE}" "${APP}/Contents/MacOS/${EXE_NAME}"
cp "${LAUNCHER_DIR}/Info.plist" "${APP}/Contents/Info.plist"

log "ad-hoc codesign"
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"

log "done: ${APP}"
echo "${APP}"
