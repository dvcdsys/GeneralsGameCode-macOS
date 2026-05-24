#pragma once
// <ocidl.h> shim for non-Windows builds.
// OLE control / automation interfaces (IOleObject, IConnectionPoint, ...). The
// engine pulls this in via PreRTS but the embedded-control features it backs
// (IE web browser) are Windows-only. Only the COM vocabulary is needed here.
// TODO(macos): the embedded IE control has no macOS replacement.
#ifndef _WIN32
#include "windows.h"
#include "objbase.h"
#include "ole2.h"
#endif
