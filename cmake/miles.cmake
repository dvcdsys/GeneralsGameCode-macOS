if(APPLE)
    # On macOS we ship a real Miles impl (AVAudioEngine + AudioToolbox) instead
    # of fetching the no-op stub. The local project still produces the
    # `milesstub` / `mss32` target so downstream linkage is unchanged.
    add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/miles_apple
                     ${CMAKE_BINARY_DIR}/miles_apple-build)
else()
    FetchContent_Declare(
        miles
        GIT_REPOSITORY https://github.com/TheSuperHackers/miles-sdk-stub.git
        GIT_TAG        6e32700d7ba4b4713a03bf1f5ffc3b0ac8d17264
    )

    FetchContent_MakeAvailable(miles)
endif()
