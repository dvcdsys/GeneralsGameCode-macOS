# External-Control API dependencies (Milestone 1).
#
# Pulls the small, cross-platform libraries used by the embedded external-control
# server: cpp-httplib (REST), nlohmann/json (JSON), and IXWebSocket (the /events
# WebSocket channel). All are fetched at configure time, mirroring the pattern
# used by lzhl.cmake / gamespy.cmake. They are bundled behind a single INTERFACE
# target `rts_external_control_deps` so the engine links one thing.
#
# Only included when RTS_BUILD_EXTERNAL_CONTROL is ON (see top-level CMakeLists).

include(FetchContent)

# --- nlohmann/json (header-only) --------------------------------------------
set(JSON_BuildTests OFF CACHE INTERNAL "")
set(JSON_Install OFF CACHE INTERNAL "")
FetchContent_Declare(nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json
    GIT_TAG        v3.11.3
    GIT_SHALLOW    TRUE
)

# --- cpp-httplib (header-only by default) -----------------------------------
# Disable ALL optional backends. The *_IF_AVAILABLE flags default ON and would
# auto-detect system OpenSSL/Brotli/Zlib; OpenSSL on macOS additionally pulls in
# CPPHTTPLIB_USE_CERTS_FROM_MACOSX_KEYCHAIN -> CoreFoundation.h -> MacTypes.h,
# whose UInt8/Byte typedefs clash with the engine's BaseTypeCore.h. We only need
# plain HTTP on 127.0.0.1, so force every backend off (FORCE overrides any prior
# cached value). REQUIRE_* alone does NOT stop auto-detection.
set(HTTPLIB_COMPILE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_REQUIRE_OPENSSL OFF CACHE BOOL "" FORCE)
set(HTTPLIB_REQUIRE_ZLIB OFF CACHE BOOL "" FORCE)
set(HTTPLIB_REQUIRE_BROTLI OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_OPENSSL_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_ZLIB_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_BROTLI_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(cpp_httplib
    GIT_REPOSITORY https://github.com/yhirose/cpp-httplib
    GIT_TAG        v0.18.3
    GIT_SHALLOW    TRUE
)

# --- IXWebSocket (compiled; TLS/zlib off for a localhost-only server) -------
set(USE_TLS OFF CACHE INTERNAL "")
set(USE_ZLIB OFF CACHE INTERNAL "")
set(IXWEBSOCKET_INSTALL OFF CACHE INTERNAL "")
FetchContent_Declare(ixwebsocket
    GIT_REPOSITORY https://github.com/machinezone/IXWebSocket
    GIT_TAG        v11.4.5
    GIT_SHALLOW    TRUE
)

FetchContent_MakeAvailable(nlohmann_json cpp_httplib ixwebsocket)

# Single aggregate target the engine links against.
add_library(rts_external_control_deps INTERFACE)
target_link_libraries(rts_external_control_deps INTERFACE
    httplib::httplib
    nlohmann_json::nlohmann_json
    ixwebsocket
)
