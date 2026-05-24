#pragma once
// <lmcons.h> shim for non-Windows builds.
// LAN Manager constants. Only the name-length limits and GetUserName are used.
#ifndef _WIN32

#include "windows.h"

#ifndef UNLEN
#define UNLEN     256   // max user name length
#define CNLEN     15    // max computer name length
#define DNLEN     15    // max domain name length
#define PWLEN     256   // max password length
#define NNLEN     80    // max net name length
#endif

// GetUserNameA: narrow alias for GetUserName (already provided by win32_api.h).
inline BOOL GetUserNameA(char *buffer, DWORD *size) { return GetUserName(buffer, size); }

#endif // !_WIN32
