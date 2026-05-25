#!/usr/bin/env bash
# Build + run the fileio_check harness.
# Standalone — no engine libs needed. Just c++17 std::filesystem.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC=/usr/bin/c++
OUT="$ROOT/macos_port_tests/build/fileio_check"

mkdir -p "$ROOT/macos_port_tests/build"

echo "==> Compiling fileio_check"
"$CC" -std=c++17 -O0 -g -arch arm64 -mmacosx-version-min=12.0 \
    -o "$OUT" \
    "$ROOT/macos_port_tests/fileio_check.cpp"

# Default to the install location used in this dev environment.
: "${GAMEDIR:=/Users/dvcdsys/Command and Conquer Generals Zero Hour/Command and Conquer Generals Zero Hour}"
export GAMEDIR

echo "==> Running fileio_check with GAMEDIR='$GAMEDIR'"
"$OUT"
