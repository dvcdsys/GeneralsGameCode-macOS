#pragma once
// <windowsx.h> shim -> message-cracker / param helper macros used by window code.
#include <windows.h>
#ifndef GET_X_LPARAM
#define GET_X_LPARAM(lp) ((int)(short)LOWORD(lp))
#endif
#ifndef GET_Y_LPARAM
#define GET_Y_LPARAM(lp) ((int)(short)HIWORD(lp))
#endif

#ifndef _WIN32
// GlobalAllocPtr / GlobalFreePtr: <windowsx.h> convenience macros that allocate
// and return a usable pointer directly (instead of a movable HGLOBAL handle).
// On macOS our GlobalAlloc already returns a fixed pointer-as-handle, so these
// map straight onto it.
#ifndef GlobalAllocPtr
#define GlobalAllocPtr(flags, cb)   ((void *)GlobalAlloc((flags), (cb)))
#endif
#ifndef GlobalFreePtr
#define GlobalFreePtr(p)            (GlobalFree((HGLOBAL)(p)))
#endif
#endif
