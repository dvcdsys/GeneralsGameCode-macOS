#pragma once

// Minimal <ddraw.h> (DirectDraw) compatibility shim for non-Windows builds.
//
// The WW3D2 DDS texture loader (ddsfile.cpp) includes <ddraw.h> only to obtain
// a handful of DDSCAPS2_* surface-capability flags it tests against values it
// reads out of a .dds file header. It does not use any DirectDraw COM
// interface on the non-Windows path, so we only supply the flag constants and
// the MAKEFOURCC helper here. The full DirectDraw SDK header is fetched at
// _deps/dx8-src/extra/ddraw.h for the Windows build.
//
// TODO(macos): no DirectDraw on macOS; texture upload happens via the future
// Metal back end. These constants only have to parse and match the file format.

#ifndef _WIN32

#include <windows.h>

#ifndef MAKEFOURCC
#define MAKEFOURCC(ch0, ch1, ch2, ch3) \
    ((DWORD)(BYTE)(ch0) | ((DWORD)(BYTE)(ch1) << 8) | \
    ((DWORD)(BYTE)(ch2) << 16) | ((DWORD)(BYTE)(ch3) << 24))
#endif

// DDSCAPS2 surface-capability flags (from the DirectDraw SDK). Only the cubemap
// and volume bits are tested by ddsfile.cpp; values match the real header.
#ifndef DDSCAPS2_CUBEMAP
#define DDSCAPS2_CUBEMAP            0x00000200u
#define DDSCAPS2_CUBEMAP_POSITIVEX  0x00000400u
#define DDSCAPS2_CUBEMAP_NEGATIVEX  0x00000800u
#define DDSCAPS2_CUBEMAP_POSITIVEY  0x00001000u
#define DDSCAPS2_CUBEMAP_NEGATIVEY  0x00002000u
#define DDSCAPS2_CUBEMAP_POSITIVEZ  0x00004000u
#define DDSCAPS2_CUBEMAP_NEGATIVEZ  0x00008000u
#define DDSCAPS2_VOLUME             0x00200000u
#endif

#endif // !_WIN32
