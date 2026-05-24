#pragma once

// Minimal <vfw.h> (Video for Windows) compatibility shim for non-Windows.
//
// WW3D2's FrameGrabClass (framgrab.h / FramGrab.cpp) uses the AVIFile API to
// record gameplay to an .avi file. This is a Windows-only debug/capture
// feature with no analogue on macOS. We provide just enough types, constants
// and inline no-op functions for the code to compile; every AVI operation
// fails or does nothing, so frame capture is simply unavailable at runtime.
//
// TODO(macos): if video capture is ever wanted, back this with AVFoundation.

#ifndef _WIN32

#include <windows.h>

// Opaque AVI handles.
typedef void* PAVIFILE;
typedef void* PAVISTREAM;

// AVISTREAMINFO (ANSI). Field set matches what FramGrab.cpp writes.
#ifndef _AVISTREAMINFO_DEFINED
#define _AVISTREAMINFO_DEFINED
typedef struct _AVISTREAMINFOA {
  DWORD fccType;
  DWORD fccHandler;
  DWORD dwFlags;
  DWORD dwCaps;
  WORD  wPriority;
  WORD  wLanguage;
  DWORD dwScale;
  DWORD dwRate;
  DWORD dwStart;
  DWORD dwLength;
  DWORD dwInitialFrames;
  DWORD dwSuggestedBufferSize;
  DWORD dwQuality;
  DWORD dwSampleSize;
  RECT  rcFrame;
  DWORD dwEditCount;
  DWORD dwFormatChangeCount;
  char  szName[64];
} AVISTREAMINFOA, *LPAVISTREAMINFOA;
typedef AVISTREAMINFOA AVISTREAMINFO;
typedef LPAVISTREAMINFOA LPAVISTREAMINFO;
#endif

// Stream-type / write / file-open flag constants.
#ifndef mmioFOURCC
#define mmioFOURCC(c0, c1, c2, c3) \
    ((DWORD)(BYTE)(c0) | ((DWORD)(BYTE)(c1) << 8) | \
    ((DWORD)(BYTE)(c2) << 16) | ((DWORD)(BYTE)(c3) << 24))
#endif
#ifndef streamtypeVIDEO
#define streamtypeVIDEO mmioFOURCC('v','i','d','s')
#define streamtypeAUDIO mmioFOURCC('a','u','d','s')
#endif
#ifndef AVIIF_KEYFRAME
#define AVIIF_KEYFRAME 0x00000010u
#endif
#ifndef OF_WRITE
#define OF_READ   0x00000000u
#define OF_WRITE  0x00000001u
#define OF_CREATE 0x00001000u
#endif

// SetRect helper (USER32) used to fill rcFrame.
#ifndef _OSDEP_HAS_SETRECT
#define _OSDEP_HAS_SETRECT
inline BOOL SetRect(RECT *r, int l, int t, int rr, int b)
{ if (!r) return FALSE; r->left = l; r->top = t; r->right = rr; r->bottom = b; return TRUE; }
#endif

// AVIFile API -> no-ops returning failure. TODO(macos): AVFoundation capture.
inline void    AVIFileInit() {}
inline void    AVIFileExit() {}
inline HRESULT AVIFileOpen(PAVIFILE *pf, const char *, UINT, void *) { if (pf) *pf = nullptr; return E_FAIL; }
inline HRESULT AVIFileCreateStream(PAVIFILE, PAVISTREAM *ps, AVISTREAMINFO *) { if (ps) *ps = nullptr; return E_FAIL; }
inline HRESULT AVIStreamSetFormat(PAVISTREAM, LONG, void *, LONG) { return E_FAIL; }
inline HRESULT AVIStreamWrite(PAVISTREAM, LONG, LONG, void *, LONG, DWORD, LONG *, LONG *) { return E_FAIL; }
inline ULONG   AVIStreamRelease(PAVISTREAM) { return 0; }
inline ULONG   AVIFileRelease(PAVIFILE) { return 0; }

#endif // !_WIN32
