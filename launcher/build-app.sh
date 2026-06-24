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

# Version stamping: VERSION (set by CI from a launcher-v* tag) overrides the
# static Info.plist values. Without it, the template's dev defaults are kept.
VERSION="${VERSION:-}"
if [ -n "${VERSION}" ]; then
	PB=/usr/libexec/PlistBuddy
	"${PB}" -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
	# CFBundleVersion must be monotonic; use the git commit count when available.
	BUILDNUM="$(git -C "${ROOT_DIR}" rev-list --count HEAD 2>/dev/null || echo 1)"
	"${PB}" -c "Set :CFBundleVersion ${BUILDNUM}" "${APP}/Contents/Info.plist"
	log "stamped version ${VERSION} (build ${BUILDNUM})"
fi

# Bundle the API docs so the launcher's "API Docs" tab can render them offline.
log "bundling docs"
DOCS_DST="${APP}/Contents/Resources/docs"
mkdir -p "${DOCS_DST}"
copy_doc() { # src dst
	if [ -f "$1" ]; then cp "$1" "${DOCS_DST}/$2"; else log "WARN missing doc: $1"; fi
}
copy_doc "${ROOT_DIR}/docs/EXTERNAL_CONTROL_API.md"      "EXTERNAL_CONTROL_API.md"
copy_doc "${ROOT_DIR}/game_agent/docs/ARCHITECTURE.md"   "ARCHITECTURE.md"
copy_doc "${ROOT_DIR}/game_agent/docs/AGENT.md"          "AGENT.md"
copy_doc "${ROOT_DIR}/game_agent/docs/HARNESS.md"        "HARNESS.md"
copy_doc "${ROOT_DIR}/game_agent/docs/COMMANDER_PLAN.md" "COMMANDER_PLAN.md"
copy_doc "${ROOT_DIR}/game_agent/README.md"              "AGENT_README.md"

log "ad-hoc codesign"
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}"

log "done: ${APP}"
echo "${APP}"
