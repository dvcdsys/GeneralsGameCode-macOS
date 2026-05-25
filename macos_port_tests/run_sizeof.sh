#!/usr/bin/env bash
# Build + run the sizeof harness using engine compile flags.
# Iteration loop target: <5 seconds total.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC=/usr/bin/c++
OUT="$ROOT/macos_port_tests/build/sizeof_check"

INCLUDES=(
    -I"$ROOT/GeneralsMD/Code/GameEngine/Include"
    -I"$ROOT/GeneralsMD/Code/GameEngine/Include/Precompiled"
    -I"$ROOT/Dependencies/Utility/osdep_compat"
    -I"$ROOT/Dependencies/Utility"
    -I"$ROOT/Core/Libraries/Include"
    -I"$ROOT/Core/GameEngine/Include"
    -I"$ROOT/Core/Libraries/Source/WWVegas"
    -I"$ROOT/Core/Libraries/Source/WWVegas/WWLib"
    -I"$ROOT/Core/Libraries/Source/WWVegas/WWMath"
    -I"$ROOT/Core/Libraries/Source/WWVegas/WWDebug"
)

DEFINES=(
    -DBUILD_WITH_D3D8
    -DDEBUG_LOGGING=1
    -DDISABLE_DEBUG_CRASHING=1
    -DDISABLE_DEBUG_PROFILE=1
    -DDISABLE_DEBUG_STACKTRACE=1
    -DDISABLE_MEMORYPOOL_CHECKPOINTING=1
    -DDISABLE_MEMORYPOOL_STACKTRACE=1
    -DIG_DEBUG_STACKTRACE
    -DNDEBUG
    -DRTS_PLATFORM_APPLE=1
    -DRTS_RELEASE
    -DRTS_ZEROHOUR=1
    -D_UNIX
    -D_USE_MATH_DEFINES
)

FLAGS=(
    -std=c++20
    -arch arm64
    -mmacosx-version-min=12.0
    -fno-strict-aliasing
    -Wno-deprecated-declarations
    -fdeclspec
)

mkdir -p "$ROOT/macos_port_tests/build"

echo "==> Compiling sizeof_check.cpp"
time "$CC" "${INCLUDES[@]}" "${DEFINES[@]}" "${FLAGS[@]}" \
    -o "$OUT" "$ROOT/macos_port_tests/sizeof_check.cpp"

echo
echo "==> Running sizeof_check"
"$OUT"
