#pragma once
// <dinput.h> wrapper for non-Windows builds.
//
// The min-dx8-sdk dinput.h emits DEFINE_GUID(...) for all DirectInput CLSIDs
// and IIDs unconditionally, but only pulls in <objbase.h> (which provides the
// DEFINE_GUID/GUID machinery) under `#ifdef _WIN32`. On macOS that leaves the
// GUID definitions with no type, so we pre-include objbase.h here, then forward
// to the real SDK header via include_next (osdep_compat precedes dx8-src on the
// include path).
//
// TODO(macos): DirectInput is not functional on macOS; real input handling is
// planned via SDL in a later phase. These GUIDs are only referenced (never
// matched against a live COM object), so the real DirectInput values that the
// SDK header supplies are harmless.
#ifndef _WIN32
#include <objbase.h>
#endif

#if defined(__has_include_next)
#  if __has_include_next(<dinput.h>)
#    include_next <dinput.h>
#  endif
#else
#  include_next <dinput.h>
#endif
