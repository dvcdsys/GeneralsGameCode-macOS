#!/usr/bin/env bash
#
# package-macos-release.sh — assemble a relocatable, self-contained macOS
# arm64 release payload for the Zero Hour engine binary (`generalszh`).
#
# The freshly built binary links its two helper dylibs (binkw32 / mss32) via
# @rpath, and the rpaths point at absolute paths inside the build tree
# (build/apple-arm64/_deps/.../Release). Those paths only exist on the machine
# that built it, so a raw copy of the binary will not run anywhere else.
#
# This script copies the binary + dylibs into one flat directory, rewrites the
# rpath to @loader_path (so the loader finds the dylibs sitting next to the
# binary), re-applies an ad-hoc code signature (install_name_tool invalidates
# the old one — and arm64 refuses to run unsigned Mach-O), then zips the result
# with `ditto` and writes a SHA256SUMS file.
#
# Output: dist/GeneralsZH-macOS-arm64/        (the payload directory)
#         dist/GeneralsZH-macOS-arm64.zip     (the release asset)
#         dist/SHA256SUMS
#
# Usage:
#   scripts/package-macos-release.sh [CONFIG] [BUILD_DIR]
#     CONFIG     build config to package        (default: Release)
#     BUILD_DIR  cmake binary dir               (default: build/apple-arm64)
#
# Env overrides: CONFIG, BUILD_DIR, DIST_DIR, PAYLOAD_NAME.

set -euo pipefail

# --- locate repo root (this script lives in <root>/scripts) ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${1:-${CONFIG:-Release}}"
BUILD_DIR="${2:-${BUILD_DIR:-${ROOT_DIR}/build/apple-arm64}}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
PAYLOAD_NAME="${PAYLOAD_NAME:-GeneralsZH-macOS-arm64}"

PAYLOAD_DIR="${DIST_DIR}/${PAYLOAD_NAME}"
ZIP_PATH="${DIST_DIR}/${PAYLOAD_NAME}.zip"

BIN_SRC="${BUILD_DIR}/GeneralsMD/${CONFIG}/generalszh"
BINK_DIR="${BUILD_DIR}/_deps/bink-build/${CONFIG}"

log()  { printf '\033[1;36m[package]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[package] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "${BIN_SRC}" ] || die "binary not found: ${BIN_SRC} (build the Release target first)"
[ -d "${BINK_DIR}" ]  || die "bink dylib dir not found: ${BINK_DIR}"

# --- fresh payload dir --------------------------------------------------------
log "config=${CONFIG}  build=${BUILD_DIR}"
rm -rf "${PAYLOAD_DIR}" "${ZIP_PATH}"
mkdir -p "${PAYLOAD_DIR}"

# --- copy binary + dylibs (preserve the version symlink chain) ---------------
cp -p "${BIN_SRC}" "${PAYLOAD_DIR}/generalszh"
# -a keeps symlinks: libfoo.dylib -> libfoo.1.0.dylib -> libfoo.1.0.0.dylib
# Bink is a real @rpath dylib the binary links — always bundle it.
cp -a "${BINK_DIR}/"libbinkw32*.dylib "${PAYLOAD_DIR}/"
# Miles is built statically into the binary on the macOS port (cmake/miles_apple),
# so there is normally no libmss32 dylib to ship. Bundle one only if a dylib-based
# layout produced it (handles both _deps/miles-build and miles_apple-build).
for _mdir in "${BUILD_DIR}/_deps/miles-build/${CONFIG}" "${BUILD_DIR}/miles_apple-build/${CONFIG}"; do
    if compgen -G "${_mdir}/libmss32*.dylib" > /dev/null 2>&1; then
        log "bundling Miles dylib from ${_mdir}"
        cp -a "${_mdir}/"libmss32*.dylib "${PAYLOAD_DIR}/"
        break
    fi
done

BIN="${PAYLOAD_DIR}/generalszh"

# --- rewrite rpaths: drop absolute build-tree paths, add @loader_path --------
# Discover every LC_RPATH currently baked into the binary and delete the ones
# that point at an absolute filesystem path (those are the build-machine paths).
# We do NOT hardcode the runner's checkout path so this works locally and in CI.
log "rewriting rpaths -> @loader_path"
while IFS= read -r rp; do
	case "${rp}" in
		/*)
			install_name_tool -delete_rpath "${rp}" "${BIN}" 2>/dev/null || true
			;;
	esac
done < <(otool -l "${BIN}" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')

# Add @loader_path only if not already present.
if ! otool -l "${BIN}" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | grep -qx '@loader_path'; then
	install_name_tool -add_rpath '@loader_path' "${BIN}"
fi

# --- re-sign (ad-hoc): dylibs first, then the binary -------------------------
# install_name_tool invalidates any existing signature; arm64 Mach-O must carry
# at least an ad-hoc signature to be allowed to execute.
log "ad-hoc codesign"
for dylib in "${PAYLOAD_DIR}"/*.dylib; do
	# skip symlinks — sign only the real files
	[ -L "${dylib}" ] && continue
	codesign --force --sign - --timestamp=none "${dylib}"
done
codesign --force --sign - --timestamp=none "${BIN}"
codesign --verify --deep --strict "${BIN}" || die "codesign verification failed"

# --- sanity: the binary must resolve its dylibs via @rpath -------------------
log "linked dylibs:"
otool -L "${BIN}" | sed 's/^/    /'

# --- zip with ditto (preserves macOS metadata) -------------------------------
log "creating ${ZIP_PATH}"
( cd "${DIST_DIR}" && ditto -c -k --keepParent "${PAYLOAD_NAME}" "${PAYLOAD_NAME}.zip" )

# --- checksums ---------------------------------------------------------------
( cd "${DIST_DIR}" && shasum -a 256 "${PAYLOAD_NAME}.zip" | tee -a SHA256SUMS )

log "done: ${ZIP_PATH}"
