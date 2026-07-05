add_executable(z_generals WIN32)

# Use a binary name that doesn't conflict with original game.
if("${CMAKE_SYSTEM}" MATCHES "Windows")
    set_target_properties(z_generals PROPERTIES OUTPUT_NAME "generalszh${RTS_BUILD_OUTPUT_SUFFIX}")
else()
    set_target_properties(z_generals PROPERTIES OUTPUT_NAME "generalszh${RTS_BUILD_OUTPUT_SUFFIX}")
endif()

target_link_libraries(z_generals PRIVATE
    binkstub
    core_debug
    core_profile_legacy
    d3d8
    d3dx8
    dinput8
    dxguid
    milesstub
    z_gameengine
    z_gameenginedevice
    zi_always
)

# Windows-only system import libraries. On macOS the engine code that used these
# is satisfied by the header-only Win32 shims (osdep_compat), so they are not linked.
if(WIN32 OR "${CMAKE_SYSTEM}" MATCHES "Windows")
    target_link_libraries(z_generals PRIVATE
        comctl32
        imm32
        vfw32
        winmm
    )
endif()

# TODO Originally referred to build host and user, replace with git info perhaps?
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/GeneratedVersion.h
"#pragma once

#define VERSION_LOCALBUILDNUM 0
#define VERSION_BUILDUSER \"\"
#define VERSION_BUILDLOC \"\"
"
)

# Engine version: semver derived from the release tag (engine-vMAJOR.MINOR.PATCH).
# CI passes -DRTS_VERSION=X.Y.Z explicitly; otherwise fall back to the latest
# engine-v* git tag, then to 0.0.0 for an untagged working tree.
if(NOT DEFINED RTS_VERSION OR RTS_VERSION STREQUAL "")
    find_package(Git QUIET)
    set(RTS_VERSION "0.0.0")
    if(GIT_FOUND)
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" describe --tags --match "engine-v*" --abbrev=0
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            OUTPUT_VARIABLE _git_engine_tag
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET)
        if(_git_engine_tag MATCHES "engine-v([0-9]+\\.[0-9]+\\.[0-9]+)")
            set(RTS_VERSION "${CMAKE_MATCH_1}")
        endif()
    endif()
endif()

# Extract MAJOR.MINOR.PATCH from RTS_VERSION, tolerating an optional leading
# prefix (engine-v / v). A single capturing match avoids string(REGEX REPLACE),
# which errors under newer CMake when the strip pattern matches an empty string
# (e.g. RTS_VERSION="0.0.0" has no prefix to strip -> hard "matched an empty
# string" error that failed every GeneralsMD configure in GenCI).
if(RTS_VERSION MATCHES "([0-9]+)\\.([0-9]+)\\.([0-9]+)")
    set(_RTS_VMAJOR "${CMAKE_MATCH_1}")
    set(_RTS_VMINOR "${CMAKE_MATCH_2}")
    set(_RTS_VPATCH "${CMAKE_MATCH_3}")
else()
    set(_RTS_VMAJOR 0)
    set(_RTS_VMINOR 0)
    set(_RTS_VPATCH 0)
endif()
message(STATUS "Zero Hour engine version: ${_RTS_VMAJOR}.${_RTS_VMINOR}.${_RTS_VPATCH} (RTS_VERSION=${RTS_VERSION})")

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/BuildVersion.h
"#pragma once

#define VERSION_MAJOR ${_RTS_VMAJOR}
#define VERSION_MINOR ${_RTS_VMINOR}
#define VERSION_BUILDNUM ${_RTS_VPATCH}
"
)

if(MSVC)
    target_link_options(z_generals PRIVATE "/NODEFAULTLIB:libci.lib")
endif()

target_include_directories(z_generals PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
)

target_sources(z_generals PRIVATE
    WinMain.cpp
    WinMain.h
)

# RC files optional for MinGW builds
# Icon: LoadIcon() handles missing resource gracefully (uses default system icon)
# Manifest: DPI awareness metadata (nice to have but not essential)
if(MSVC)
    # VS2005 and later adds default manifest, we need to turn it off to prevent conflict with custom manifest
    if(NOT IS_VS6_BUILD)
        target_link_options(z_generals PRIVATE
            "/MANIFEST:NO"
        )
    endif()

    target_sources(z_generals PRIVATE
        RTS.RC
    )
endif()

# Strip debug symbols to separate file for MinGW Release builds
# This creates generalszh${RTS_BUILD_OUTPUT_SUFFIX}.exe.debug (similar to MSVC .pdb files)
if(MINGW AND COMMAND add_debug_strip_target)
    add_debug_strip_target(z_generals)
endif()
