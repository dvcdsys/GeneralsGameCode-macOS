set(GS_OPENSSL FALSE)
set(GAMESPY_SERVER_NAME "server.cnc-online.net")

FetchContent_Declare(
    gamespy
    GIT_REPOSITORY https://github.com/TheAssemblyArmada/GamespySDK.git
    GIT_TAG        07e3d15c500415abc281efb74322ab6d9c857eb8
)

FetchContent_MakeAvailable(gamespy)

# GamespySDK auto-defines _LINUX in gscommon.h when __linux__ is set but has
# no equivalent for Apple, so every #elif defined(_MACOSX) branch is skipped
# and gsdebug.c (etc.) falls through to a #else branch that uses va_start on
# a function declared with a va_list parameter — fails to compile on clang.
# Apply the platform define to every gamespy OBJECT/library target. Scoped to
# Apple so Windows/Linux builds are untouched.
if(APPLE)
    # gsinterface is INTERFACE — defines must use INTERFACE; everything else is
    # a regular OBJECT/STATIC target. We list known targets explicitly and skip
    # any that don't exist (gamespy doesn't build every component on every
    # platform). The PUBLIC link from each consumer to gsinterface propagates
    # the defines down further, but we apply directly to consumers too as a
    # belt-and-suspenders against an order-of-evaluation surprise.
    foreach(_gs_tgt
            gsinterface gscommon gsbrigades gsdevreport gsgp gsgt2 ghttp gpeer
            gsnatneg gsqr2 gssake gssc gsserverbrowsing gst2 gsthread gsvoice2
            gswebservices)
        if(TARGET ${_gs_tgt})
            get_target_property(_gs_type ${_gs_tgt} TYPE)
            if(_gs_type STREQUAL "INTERFACE_LIBRARY")
                target_compile_definitions(${_gs_tgt} INTERFACE _MACOSX _UNIX)
            else()
                target_compile_definitions(${_gs_tgt} PRIVATE _MACOSX _UNIX)
            endif()
        endif()
    endforeach()
endif()
