#!/usr/bin/env bash
# Build + run the RandomClass determinism harness.
# Links against the actual engine WWLib (libwwlib.a) so we exercise the
# real RandomClass code, not a copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC=/usr/bin/c++
OUT="$ROOT/macos_port_tests/build/random_check"
BUILD_DIR="$ROOT/build/apple-arm64"

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
    -include "$ROOT/Dependencies/Utility/Utility/CppMacros.h"
)

# We compile our own copy of random.cpp into the harness so we don't need
# to drag in the full WWLib archive (which would require resolving stub
# helpers and the memory pool).
WWLIB_SRC="$ROOT/Core/Libraries/Source/WWVegas/WWLib/random.cpp"

mkdir -p "$ROOT/macos_port_tests/build"

echo "==> Compiling random_check.cpp + random.cpp"
time "$CC" "${INCLUDES[@]}" "${DEFINES[@]}" "${FLAGS[@]}" \
    -o "$OUT" \
    "$ROOT/macos_port_tests/random_check.cpp" \
    "$WWLIB_SRC"

echo
echo "==> Running random_check"
"$OUT"
