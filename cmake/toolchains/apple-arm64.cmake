# macOS Apple Silicon (arm64) Toolchain File
# Use with: cmake --preset apple-arm64
#
# This toolchain targets native macOS on Apple Silicon (M1/M2/M3+) only.
# x86_64 Intel Macs are not supported by this preset; use a Rosetta/Wine path instead.
#
# Minimum macOS target is 12.0 (Monterey) for full Metal feature parity and
# stable MoltenVK/Vulkan support.

set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")

# 64-bit pointers — the original 32-bit assumption is bypassed by the
# platform-aware gate in the root CMakeLists.txt.
set(CMAKE_SIZEOF_VOID_P 8)

# Disable MFC-dependent tools (Windows-only).
set(RTS_BUILD_CORE_TOOLS OFF CACHE BOOL "Disable MFC-dependent core tools on macOS" FORCE)
set(RTS_BUILD_GENERALS_TOOLS OFF CACHE BOOL "Disable MFC-dependent Generals tools on macOS" FORCE)
set(RTS_BUILD_ZEROHOUR_TOOLS OFF CACHE BOOL "Disable MFC-dependent Zero Hour tools on macOS" FORCE)
