#pragma once
// <shlguid.h> shim for non-Windows builds.
// Shell interface GUIDs. None are matched against live COM objects on macOS;
// this header exists only so the PreRTS include resolves.
#ifndef _WIN32
#include "windows.h"
#include "objbase.h"
#endif
