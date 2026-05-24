#pragma once
// Minimal <ole2.h> shim. The engine includes it but only references OLE init
// (which is commented out). Provide the COM/OLE umbrella + no-op init.
#ifndef _WIN32
#include <windows.h>
#include "objbase.h"
inline HRESULT OleInitialize(void*) { return S_OK; }
inline void    OleUninitialize() {}
#endif
