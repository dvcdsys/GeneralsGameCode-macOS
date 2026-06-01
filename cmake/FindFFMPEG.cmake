# FindFFMPEG.cmake — pkg-config-driven FFmpeg locator.
#
# Discovers libavformat / libavcodec / libswscale / libavutil
# (+ optional libswresample) via pkg-config and exposes the
# variables Core/GameEngineDevice/CMakeLists.txt expects:
#
#   FFMPEG_FOUND
#   FFMPEG_INCLUDE_DIRS
#   FFMPEG_LIBRARY_DIRS
#   FFMPEG_LIBRARIES
#
# Why this module exists: the engine's FFmpeg path was authored on
# Windows/Linux against an upstream FindFFMPEG that never landed in
# CMake's default modules. On macOS we lean on Homebrew's pkg-config
# files (`brew install ffmpeg`) — they cover both header and library
# search paths and Just Work for `find_package(FFMPEG REQUIRED)`.

find_package(PkgConfig QUIET)

if(NOT PKG_CONFIG_FOUND)
    set(FFMPEG_FOUND FALSE)
    if(FFMPEG_FIND_REQUIRED)
        message(FATAL_ERROR "FindFFMPEG: pkg-config not found. Install pkgconf (Homebrew: `brew install pkgconf`).")
    endif()
    return()
endif()

# Required components — anything missing is a hard fail (matches
# `find_package(FFMPEG REQUIRED)` semantics downstream).
set(_ffmpeg_required_modules
    libavformat
    libavcodec
    libswscale
    libavutil
)

# Optional — present on every modern FFmpeg build but the cutscene
# code only uses it via the OpenAL path, so we don't hard-require it.
set(_ffmpeg_optional_modules
    libswresample
)

set(FFMPEG_INCLUDE_DIRS)
set(FFMPEG_LIBRARY_DIRS)
set(FFMPEG_LIBRARIES)

set(_ffmpeg_missing)
foreach(_mod IN LISTS _ffmpeg_required_modules)
    pkg_check_modules(_pc_${_mod} QUIET ${_mod})
    if(_pc_${_mod}_FOUND)
        list(APPEND FFMPEG_INCLUDE_DIRS ${_pc_${_mod}_INCLUDE_DIRS})
        list(APPEND FFMPEG_LIBRARY_DIRS ${_pc_${_mod}_LIBRARY_DIRS})
        list(APPEND FFMPEG_LIBRARIES   ${_pc_${_mod}_LIBRARIES})
    else()
        list(APPEND _ffmpeg_missing ${_mod})
    endif()
endforeach()

foreach(_mod IN LISTS _ffmpeg_optional_modules)
    pkg_check_modules(_pc_${_mod} QUIET ${_mod})
    if(_pc_${_mod}_FOUND)
        list(APPEND FFMPEG_INCLUDE_DIRS ${_pc_${_mod}_INCLUDE_DIRS})
        list(APPEND FFMPEG_LIBRARY_DIRS ${_pc_${_mod}_LIBRARY_DIRS})
        list(APPEND FFMPEG_LIBRARIES   ${_pc_${_mod}_LIBRARIES})
    endif()
endforeach()

if(_ffmpeg_missing)
    set(FFMPEG_FOUND FALSE)
    if(FFMPEG_FIND_REQUIRED)
        message(FATAL_ERROR
            "FindFFMPEG: pkg-config could not locate these required FFmpeg components: "
            "${_ffmpeg_missing}. Install via Homebrew: `brew install ffmpeg`.")
    endif()
    return()
endif()

list(REMOVE_DUPLICATES FFMPEG_INCLUDE_DIRS)
list(REMOVE_DUPLICATES FFMPEG_LIBRARY_DIRS)
list(REMOVE_DUPLICATES FFMPEG_LIBRARIES)

set(FFMPEG_FOUND TRUE)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(FFMPEG
    REQUIRED_VARS FFMPEG_INCLUDE_DIRS FFMPEG_LIBRARIES
)
