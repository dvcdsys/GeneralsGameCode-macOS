#pragma once

// Minimal <objbase.h> COM compatibility shim for non-Windows builds.
//
// The min-dx8-sdk headers `#include <objbase.h>` and use the classic COM
// "interface = abstract C++ class" macros (STDMETHOD / THIS / DECLARE_INTERFACE
// / DEFINE_GUID). On macOS these come from nowhere, so we model them here.
//
// Note: in d3d8.h the actual COM *interface* declarations and IIDs are guarded
// by `#if defined(_WIN32)`, which this port does not define — so the bulk of
// COM is skipped. These macros exist mainly so any ungated usage still parses.

#ifndef _WIN32

#include "windows.h"

// "interface" keyword used by the SDK headers.
#ifndef interface
#define interface struct
#endif

// Calling-convention placeholders for COM methods.
#ifndef STDMETHODCALLTYPE
#define STDMETHODCALLTYPE
#endif
#ifndef STDMETHODVCALLTYPE
#define STDMETHODVCALLTYPE
#endif
#ifndef STDAPICALLTYPE
#define STDAPICALLTYPE
#endif

// Method declaration macros (abstract virtual member functions).
#ifndef STDMETHOD
#define STDMETHOD(method)        virtual HRESULT STDMETHODCALLTYPE method
#endif
#ifndef STDMETHOD_
#define STDMETHOD_(type, method) virtual type STDMETHODCALLTYPE method
#endif
#ifndef STDMETHODV
#define STDMETHODV(method)       virtual HRESULT STDMETHODVCALLTYPE method
#endif
#ifndef STDMETHODV_
#define STDMETHODV_(type, method) virtual type STDMETHODVCALLTYPE method
#endif

// Method *implementation* macros (used to define out-of-line COM methods).
#ifndef STDMETHODIMP
#define STDMETHODIMP        HRESULT STDMETHODCALLTYPE
#endif
#ifndef STDMETHODIMP_
#define STDMETHODIMP_(type) type STDMETHODCALLTYPE
#endif

#ifndef PURE
#define PURE = 0
#endif
#ifndef THIS_
#define THIS_
#endif
#ifndef THIS
#define THIS void
#endif

// Free-function declaration macros.
#ifndef STDAPI
#define STDAPI          extern "C" HRESULT STDAPICALLTYPE
#endif
#ifndef STDAPI_
#define STDAPI_(type)   extern "C" type STDAPICALLTYPE
#endif

// Interface declaration macros.
#ifndef DECLARE_INTERFACE
#define DECLARE_INTERFACE(iface)             struct iface
#endif
#ifndef DECLARE_INTERFACE_
#define DECLARE_INTERFACE_(iface, baseiface) struct iface : public baseiface
#endif

// Opaque HANDLE-style declaration.
#ifndef DECLARE_HANDLE
#define DECLARE_HANDLE(name) typedef struct name##__ { int unused; } *name
#endif

// GUID definition. We emit a real (zeroed-out / value) constant so that any
// reference links; the engine's non-_WIN32 paths do not rely on real IIDs.
#ifndef DEFINE_GUID
#define DEFINE_GUID(name, l, w1, w2, b1, b2, b3, b4, b5, b6, b7, b8) \
    static const GUID name = { l, w1, w2, { b1, b2, b3, b4, b5, b6, b7, b8 } }
#endif

#ifndef REFGUID
#define REFGUID const GUID&
#endif

// IUnknown — the COM root interface.
#ifndef __IUnknown_INTERFACE_DEFINED__
#define __IUnknown_INTERFACE_DEFINED__
struct IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppvObject) = 0;
    virtual ULONG   STDMETHODCALLTYPE AddRef() = 0;
    virtual ULONG   STDMETHODCALLTYPE Release() = 0;
};
typedef IUnknown* LPUNKNOWN;
#endif

// Forward declarations for COM interfaces referenced only as pointer types by
// the DX8 SDK headers (full definitions are _WIN32-gated and unused here).
struct IStream;
struct IMalloc;
typedef IStream*  LPSTREAM;
typedef IMalloc*  LPMALLOC;

// OLE Automation IDispatch. Used by the (dead-on-macOS) IE-embedding web
// browser feature only as an opaque pointer token; model it as void*.
// TODO(macos): the embedded IE browser is Windows-only; no replacement planned.
// IDispatch: OLE Automation dispatch interface. Modelled as a minimal complete
// type (derived from IUnknown) so CComQIPtr<IDispatch> can call AddRef/Release.
// Only the WOL embedded browser uses it, and that feature is dead on macOS.
#ifndef __IDispatch_INTERFACE_DEFINED__
#define __IDispatch_INTERFACE_DEFINED__
struct IDispatch : public IUnknown {};
#endif
typedef void* LPDISPATCH;
// NB: FARPROC is defined in win32_api.h (a callable function-pointer type) so
// that GetProcAddress can return it; objbase.h pulls in windows.h above, which
// includes win32_api.h, so FARPROC is already in scope here.

#endif // !_WIN32
