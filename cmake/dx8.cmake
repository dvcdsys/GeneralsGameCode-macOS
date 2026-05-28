FetchContent_Declare(
    dx8
    GIT_REPOSITORY https://github.com/TheSuperHackers/min-dx8-sdk.git
    GIT_TAG        7bddff8c01f5fb931c3cb73d4aa8e66d303d97bc
)

FetchContent_MakeAvailable(dx8)

if(APPLE)
    # The min-dx8-sdk defines an INTERFACE target `d3d8lib` that links the bare
    # names `d3d8 dinput8 dxguid` (and `d3dx8`/`d3dx8d` on MSVC/MinGW). On Windows
    # those resolve to import libraries; on macOS they would become dangling
    # `-ld3d8` etc. flags. CMake resolves a bare name in target_link_libraries to
    # an existing TARGET of that name in preference to `-l`, so we create static
    # library targets with exactly those names backed by a fail-cleanly stub.
    #
    # min-dx8-sdk only defines `d3d8lib`; the names below are free.
    # Milestone 1: real Metal-backed DX8 device.
    #   dx8_stub.cpp     - DirectInput / D3DX math + fail-clean helpers (unchanged).
    #   dx8_device.cpp   - IDirect3D8 / IDirect3DDevice8 / resource COM subclasses
    #                      + Direct3DCreate8 (plain C++).
    #   metal_backend.mm - Cocoa window + Metal device/queue/layer (Objective-C++).
    add_library(d3d8 STATIC
        ${CMAKE_CURRENT_LIST_DIR}/dx8_stub/dx8_stub.cpp
        ${CMAKE_CURRENT_LIST_DIR}/dx8_stub/dx8_device.cpp
        ${CMAKE_CURRENT_LIST_DIR}/dx8_stub/metal_backend.mm
        ${CMAKE_CURRENT_LIST_DIR}/dx8_stub/gdi_text.mm
        ${CMAKE_CURRENT_LIST_DIR}/dx8_stub/apple_ani_cursor.mm
    )
    # core_config (osdep_compat include path + _UNIX) is not defined yet at this
    # include point, so add the Win32 shim path and UNIX define directly.
    # (RegistryClass stub lives in core_wwlib where the WWLib headers/PCH exist.)
    target_include_directories(d3d8 PRIVATE
        ${dx8_SOURCE_DIR}
        ${CMAKE_SOURCE_DIR}/Dependencies/Utility/osdep_compat
        ${CMAKE_SOURCE_DIR}/Dependencies/Utility
    )
    target_compile_definitions(d3d8 PRIVATE _UNIX)
    # The .mm file needs the Metal/AppKit frameworks; the C++ device code does not,
    # but linking them on the static lib's consumers is simplest via the interface.
    target_link_libraries(d3d8 PUBLIC apple_frameworks)

    add_library(dinput8 INTERFACE)
    target_link_libraries(dinput8 INTERFACE d3d8)

    add_library(dxguid INTERFACE)
    target_link_libraries(dxguid INTERFACE d3d8)

    add_library(d3dx8 INTERFACE)
    target_link_libraries(d3dx8 INTERFACE d3d8)

    add_library(d3dx8d INTERFACE)
    target_link_libraries(d3dx8d INTERFACE d3d8)

    # Milestone 1 verification: a tiny standalone executable that exercises the
    # Metal backend (Direct3DCreate8 -> CreateDevice -> Clear+Present loop)
    # without booting the full game. Run it; a window should appear and clear.
    add_executable(metal_smoketest ${CMAKE_CURRENT_LIST_DIR}/dx8_stub/metal_smoketest.cpp)
    target_include_directories(metal_smoketest PRIVATE
        ${dx8_SOURCE_DIR}
        ${CMAKE_SOURCE_DIR}/Dependencies/Utility/osdep_compat
        ${CMAKE_SOURCE_DIR}/Dependencies/Utility
    )
    target_compile_definitions(metal_smoketest PRIVATE _UNIX)
    target_link_libraries(metal_smoketest PRIVATE d3d8 apple_frameworks)
endif()
