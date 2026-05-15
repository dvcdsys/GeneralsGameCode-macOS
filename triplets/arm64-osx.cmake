set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)

set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET "12.0")

# Match the rationale of x86-windows.cmake: stop weekly toolchain bumps from
# invalidating the binary cache.
set(VCPKG_DISABLE_COMPILER_TRACKING ON)
