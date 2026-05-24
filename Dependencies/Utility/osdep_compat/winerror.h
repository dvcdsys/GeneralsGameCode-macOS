#pragma once
// <winerror.h> shim for non-Windows builds.
//
// The HRESULT / system-error vocabulary (S_OK, E_FAIL, ERROR_*, FACILITY_*,
// MAKE_HRESULT, SUCCEEDED/FAILED, ...) is already defined in the windows.h /
// win32_api.h shims. This header just forwards there so PreRTS's <winerror.h>
// include resolves.
#ifndef _WIN32
#include "windows.h"

#ifndef NOERROR
#define NOERROR 0
#endif
#ifndef S_FALSE
#define S_FALSE ((HRESULT)1L)
#endif

#endif // !_WIN32
