#!/usr/bin/env bash
# Build + run the tick_check harness (death-pipeline isolation).
# Phase 1 starts with just the memory manager.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC=/usr/bin/c++
OUT="$ROOT/macos_port_tests/build/tick_check"
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
    -I"$ROOT/Core/Libraries/Source/WWVegas/WW3D2"
    -I"$ROOT/Core/Libraries/Source/WWVegas/WWAudio"
    -I"$ROOT/Core/Libraries/Source/WWVegas/WWSaveLoad"
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

# Engine libraries built by the main project. We start with the obvious
# ones; expect to add more as the linker complains.
LIBS=(
    "$BUILD_DIR/GeneralsMD/Code/GameEngine/Release/libz_gameengine.a"
    "$BUILD_DIR/GeneralsMD/Code/GameEngineDevice/Release/libz_gameenginedevice.a"
    "$BUILD_DIR/Core/Libraries/Source/WWVegas/WWLib/Release/libwwlib.a"
    "$BUILD_DIR/Core/Libraries/Source/WWVegas/WWDebug/Release/libwwdebug.a"
    "$BUILD_DIR/Core/Libraries/Source/WWVegas/WWMath/Release/libwwmath.a"
    "$BUILD_DIR/GeneralsMD/Code/Libraries/Source/WWVegas/WW3D2/Release/libww3d2.a"
    "$BUILD_DIR/GeneralsMD/Code/Libraries/Source/WWVegas/WWAudio/Release/libwwaudio.a"
    "$BUILD_DIR/GeneralsMD/Code/Libraries/Source/WWVegas/WWDownload/Release/libwwdownload.a"
    "$BUILD_DIR/Core/Libraries/Source/WWVegas/WWStub/Release/libwwstub.a"
    "$BUILD_DIR/Core/Libraries/Source/WWVegas/WWSaveLoad/Release/libwwsaveload.a"
    "$BUILD_DIR/Core/Libraries/Source/debug/Release/libcore_debug.a"
    "$BUILD_DIR/Core/Libraries/Source/profile/Release/libcore_profile_legacy.a"
    "$BUILD_DIR/Core/Libraries/Source/Compression/Release/libcompression.a"
    "$BUILD_DIR/resources/Release/libresources.a"
    "$BUILD_DIR/Release/libliblzhl.a"
    "$BUILD_DIR/Release/libgamespy.a"
    "$BUILD_DIR/Release/libd3d8.a"
    "$BUILD_DIR/_deps/miles-build/Release/libmilescleanup.a"
)

mkdir -p "$ROOT/macos_port_tests/build"

echo "==> Compiling + linking tick_check"
time "$CC" "${INCLUDES[@]}" "${DEFINES[@]}" "${FLAGS[@]}" \
    -o "$OUT" \
    "$ROOT/macos_port_tests/tick_check.cpp" \
    "${LIBS[@]}" \
    -framework CoreFoundation -framework Foundation \
    -framework AppKit -framework IOKit \
    -framework Metal -framework MetalKit -framework QuartzCore \
    -framework CoreText -framework CoreGraphics -framework Security \
    -framework CoreServices -framework ImageIO \
    -lz -liconv

echo
if [ -x "$OUT" ]; then
    echo "==> Running tick_check"
    "$OUT"
else
    echo "BUILD FAILED — fix link errors above and retry."
    exit 1
fi
