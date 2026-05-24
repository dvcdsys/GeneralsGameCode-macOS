#pragma once
// Minimal <oleauto.h> (OLE Automation) shim for non-Windows builds.
//
// Used only by the WOL embedded-Internet-Explorer browser (FEBDispatch.h),
// which is a dead Windows-only feature on macOS. These declarations exist so
// FEBDispatch.h / WebBrowser.cpp parse and link; the implementations are
// compile-only stubs that fail gracefully (the browser is never instantiated).
// TODO(macos): no replacement for the embedded IE browser is planned.
#ifndef _WIN32

#include "windows.h"
#include "objbase.h"

// ITypeInfo / ITypeLib: OLE Automation type-description interfaces. Only the
// members FEBDispatch references are declared.
#ifndef __ITypeInfo_FWD_DEFINED__
#define __ITypeInfo_FWD_DEFINED__
struct ITypeInfo : public IUnknown {};
#endif

#ifndef __ITypeLib_FWD_DEFINED__
#define __ITypeLib_FWD_DEFINED__
struct ITypeLib : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE GetTypeInfoOfGuid(REFGUID guid, ITypeInfo** ppTInfo) { (void)guid; if (ppTInfo) *ppTInfo = nullptr; return E_FAIL; }
};
#endif

// LoadTypeLib / CreateStdDispatch: the IE-browser registration entry points.
// Both fail (no OLE on macOS); the engine logs and proceeds without a browser.
inline HRESULT LoadTypeLib(const WCHAR* /*szFile*/, ITypeLib** pptlib)
{ if (pptlib) *pptlib = nullptr; return E_FAIL; }
inline HRESULT CreateStdDispatch(IUnknown* /*punkOuter*/, void* /*pvThis*/,
                                 ITypeInfo* /*ptinfo*/, IUnknown** ppunkStdDisp)
{ if (ppunkStdDisp) *ppunkStdDisp = nullptr; return E_FAIL; }

#endif // !_WIN32
