# macOS (Darwin) build configuration. Activated when CMAKE_SYSTEM_NAME=Darwin.
#
# Mirrors the role of cmake/mingw.cmake for the Apple platform.
# Sets up:
#   - C++/Objective-C++ language flags
#   - Required system frameworks (Metal, AppKit, IOKit, ...)
#   - macOS-specific compile defines that the compat layer keys off
#
# This file does NOT pull in third-party backends (SDL2, OpenAL, MoltenVK, dxvk-native).
# Those are wired through vcpkg + target_link_libraries in their respective subprojects.

if(APPLE)
    message(STATUS "Configuring macOS (Darwin) build settings")

    if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
        message(FATAL_ERROR "macOS build requires 64-bit pointers. Apple Silicon (arm64) is the only supported target.")
    endif()

    if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
        message(WARNING "macOS x86_64 path is untested — only arm64 is supported by the apple-arm64 preset.")
    endif()

    # Allow Objective-C++ files (.mm) anywhere in the tree.
    enable_language(OBJCXX OPTIONAL)

    # Compatibility flags shared with the MinGW path — DX8 / COM headers (when used
    # via d3d8to9) rely on lax aliasing.
    add_compile_options(
        -fno-strict-aliasing
        -Wno-deprecated-declarations    # Apple deprecates plenty of POSIX symbols we still use
        -fdeclspec                      # engine + DX8/Bink stub headers use __declspec(...)
    )

    # Allow the same math constants idiom the rest of the code uses.
    add_compile_definitions(
        _USE_MATH_DEFINES
    )

    # Marker the compat headers and source files can branch on. The compat layer
    # already keys off __APPLE__; this gives the build system an extra hook.
    add_compile_definitions(
        RTS_PLATFORM_APPLE=1
    )

    # System frameworks. Linked publicly via this INTERFACE target so any
    # downstream target that wants them can just link `apple_frameworks`.
    add_library(apple_frameworks INTERFACE)
    target_link_libraries(apple_frameworks INTERFACE
        "-framework CoreFoundation"
        "-framework Foundation"
        "-framework AppKit"
        "-framework IOKit"
        "-framework Metal"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework CoreText"
        "-framework CoreGraphics"
        "-framework Security"
    )

    message(STATUS "macOS configuration complete (deployment target: ${CMAKE_OSX_DEPLOYMENT_TARGET})")
endif()
