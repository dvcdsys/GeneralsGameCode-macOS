#!/usr/bin/env bash
#
# make-dmg.sh — wrap the built launcher .app into a drag-to-Applications .dmg
# (the classic macOS installer: mount, drag the app onto the Applications folder).
#
# Prefers `create-dmg` (positioned icons + Applications drop-link); falls back to
# a plain hdiutil image (app + /Applications symlink) which always works headless.
#
# Usage:  launcher/make-dmg.sh [path/to/App.app]
# Env:    OUT_DIR  where to put the .dmg   (default: <repo>/dist)

set -euo pipefail

LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${LAUNCHER_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"

APP_NAME="GeneralsZH Launcher"
APP="${1:-${OUT_DIR}/${APP_NAME}.app}"
VOLNAME="GeneralsZH Launcher"
DMG="${OUT_DIR}/GeneralsZH-Launcher.dmg"

log() { printf '\033[1;36m[dmg]\033[0m %s\n' "$*"; }

[ -d "${APP}" ] || { echo "app not found: ${APP} (run launcher/build-app.sh first)" >&2; exit 1; }
mkdir -p "${OUT_DIR}"
rm -f "${DMG}"

if command -v create-dmg >/dev/null 2>&1; then
	log "building with create-dmg"
	# create-dmg can exit non-zero if it fails to apply the fancy AppleScript
	# layout (e.g. headless) yet still emit a valid .dmg — tolerate and verify.
	create-dmg \
		--volname "${VOLNAME}" \
		--window-size 600 360 \
		--icon-size 120 \
		--icon "${APP_NAME}.app" 160 185 \
		--app-drop-link 440 185 \
		--no-internet-enable \
		"${DMG}" "${APP}" || log "create-dmg returned non-zero (will verify output)"
fi

if [ ! -f "${DMG}" ]; then
	log "falling back to plain hdiutil DMG (app + Applications symlink)"
	STAGE="$(mktemp -d)"
	cp -R "${APP}" "${STAGE}/"
	ln -s /Applications "${STAGE}/Applications"
	hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
	rm -rf "${STAGE}"
fi

log "done: ${DMG}"
echo "${DMG}"
