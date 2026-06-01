cmake_minimum_required(VERSION 3.24.0...4.0.1)

# Real Miles Sound System impl backed by AVAudioEngine + AudioToolbox.
# Drop-in replacement for TheSuperHackers/miles-sdk-stub on macOS.
#
# Header surface (mss/mss.h) is identical to the upstream stub so the engine's
# MilesAudioManager.cpp builds unchanged. Only the .c stub bodies are replaced
# by Objective-C++ implementations in miles_apple.mm.

project(milesstub VERSION 1.0.0 LANGUAGES C CXX OBJCXX)

option(MILES_NOFLOAT "Don't use float for some volume functions." OFF)

add_library(milescleanup STATIC cleanup.c)

add_library(milesstub STATIC miles_apple.mm)
set_target_properties(milesstub PROPERTIES
    OUTPUT_NAME mss32
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

target_compile_options(milesstub PRIVATE
    -fobjc-arc
    -Wno-deprecated-declarations
)

target_include_directories(milesstub PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>      # #include <mss/mss.h>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/mss>  # #include <mss.h>
)
target_compile_definitions(milesstub PRIVATE BUILD_STUBS)

target_link_libraries(milesstub
    PRIVATE
        "-framework Foundation"
        "-framework AVFoundation"
        "-framework AudioToolbox"
        "-framework CoreAudio"
    INTERFACE
        milescleanup
)

if(MILES_NOFLOAT)
    target_compile_definitions(milesstub PUBLIC MILES_NOFLOAT)
endif()
