#pragma once
// Minimal <atlbase.h> (ATL) shim for non-Windows. The engine uses only a tiny
// ATL surface: a global CComModule `_Module`, CComPtr<>, and CComQIPtr<>.
#ifndef _WIN32
#include <windows.h>
#include "objbase.h"

// COM smart pointer (just enough: construct/assign/release/-> ).
template <class T>
class CComPtr {
public:
    T* p;
    CComPtr() : p(nullptr) {}
    CComPtr(T* lp) : p(lp) { if (p) p->AddRef(); }
    CComPtr(const CComPtr<T>& lp) : p(lp.p) { if (p) p->AddRef(); }
    ~CComPtr() { if (p) p->Release(); }
    operator T*() const { return p; }
    T& operator*() const { return *p; }
    T** operator&() { return &p; }
    T* operator->() const { return p; }
    T* operator=(T* lp) { if (p) p->Release(); p = lp; if (p) p->AddRef(); return p; }
    bool operator!() const { return p == nullptr; }
    void Release() { if (p) { p->Release(); p = nullptr; } }
};

template <class T>
class CComQIPtr {
public:
    T* p;
    CComQIPtr() : p(nullptr) {}
    CComQIPtr(T* lp) : p(lp) { if (p) p->AddRef(); }
    // Construct from any IUnknown-derived pointer via QueryInterface, mirroring
    // ATL's CComQIPtr. On macOS the COM browser feature is dead, so a failed QI
    // simply yields a null pointer (compile-only path).
    CComQIPtr(IUnknown* lp) : p(nullptr) {
        if (lp) lp->QueryInterface(__uuidof_compat(), reinterpret_cast<void**>(&p));
    }
    ~CComQIPtr() { if (p) p->Release(); }
    operator T*() const { return p; }
    T* operator->() const { return p; }
    T* operator=(T* lp) { if (p) p->Release(); p = lp; if (p) p->AddRef(); return p; }
private:
    // Placeholder IID accessor; the real IID is irrelevant since the QI always
    // fails on macOS (no COM). Returns a zeroed GUID.
    static const GUID& __uuidof_compat() { static const GUID z = {0,0,0,{0,0,0,0,0,0,0,0}}; return z; }
};

// ATL module object. The engine declares a global `CComModule _Module`.
class CComModule {
public:
    HRESULT Init(void*, HINSTANCE, const GUID* = nullptr) { return S_OK; }
    void Term() {}
    HRESULT RegisterServer(BOOL = TRUE) { return S_OK; }
    HRESULT UnregisterServer(BOOL = TRUE) { return S_OK; }
};
#endif // !_WIN32
