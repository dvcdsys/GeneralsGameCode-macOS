/*
**  Apple .ANI cursor loader — public interface used by the Win32 shim.
**
**  The engine loads cursors via the Win32 API:
**      HCURSOR hc = LoadCursorFromFile("data\\cursors\\SCCAttack_S.ANI");
**      SetCursor(hc);
**
**  On macOS we re-implement those two entry points: parse the original
**  RIFF/ACON .ANI file once (with all its embedded .CUR frames), build
**  an array of NSCursors, and expose them behind an opaque HCURSOR
**  handle. Animation between frames is driven by a single shared
**  NSTimer in the implementation file.
**
**  Apple-only. Pure C linkage so it can be called from <windows.h> shim
**  headers without dragging Objective-C through every translation unit.
*/

#pragma once

#if defined(__APPLE__)

#ifdef __cplusplus
extern "C" {
#endif

// Parse a .ANI file at the given POSIX-style path. Returns an opaque
// handle on success (caller owns nothing — the loader caches by path).
// Returns NULL on any failure (file missing, parse error, no usable
// frames). Safe to call multiple times for the same path — repeat calls
// hit the cache.
void* MetalCursor_LoadAni(const char* path);

// Make the given cached cursor active (sets the NSCursor and unhides
// the system cursor). Pass NULL to hide. Idempotent — duplicate calls
// to set the same cursor are a no-op so the per-frame engine SetCursor
// loop stays cheap.
void MetalCursor_SetActiveAni(void* handle);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // __APPLE__
