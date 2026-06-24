/*
**  macOS/non-Windows stub for the MIDL-generated BrowserDispatch.h.
**
**  On Windows this header is produced by the MIDL compiler from
**  BrowserDispatch.idl. MIDL is Windows-only, so on other platforms we hand-
**  write the minimal pieces the engine references: the IBrowserDispatch COM
**  interface and its IID. The embedded Internet-Explorer browser this backs is
**  a dead Windows-only feature on macOS.
**
**  TODO(macos): the WOL embedded browser has no macOS replacement; this exists
**  purely so GameNetwork/WOLBrowser/WebBrowser.h compiles.
*/
#pragma once

#if !defined(_WIN32)

#include <windows.h>
#include <objbase.h>

#ifndef __IBrowserDispatch_INTERFACE_DEFINED__
#define __IBrowserDispatch_INTERFACE_DEFINED__

// IID_IBrowserDispatch — value taken from BrowserDispatch.idl
// (BC834510-C5BC-4B90-8C9A-0E4B1998796F).
DEFINE_GUID(IID_IBrowserDispatch,
            0xBC834510, 0xC5BC, 0x4B90, 0x8C, 0x9A, 0x0E, 0x4B, 0x19, 0x98, 0x79, 0x6F);

// IBrowserDispatch : IUnknown { HRESULT TestMethod(int); }
struct IBrowserDispatch : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE TestMethod(int num1) = 0;
};

#endif // __IBrowserDispatch_INTERFACE_DEFINED__

// CLSID of the (never-instantiated on macOS) coclass.
DEFINE_GUID(LIBID_BROWSERDISPATCHLib,
            0xC92D8250, 0xA628, 0x4CE5, 0x82, 0x3F, 0x1A, 0x1F, 0x11, 0x6E, 0xFC, 0xC9);

#endif // !_WIN32
