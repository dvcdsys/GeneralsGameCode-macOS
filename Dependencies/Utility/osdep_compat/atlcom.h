#pragma once
// Minimal <atlcom.h> (ATL COM object support) shim for non-Windows builds.
//
// Used only by the WOL embedded-Internet-Explorer browser (FEBDispatch.h /
// WebBrowser.h), a dead Windows-only feature on macOS. These provide just
// enough of the ATL COM-object surface for those headers to compile:
//   CComObjectRootEx / CComCoClass / CComObject / CComSingleThreadModel and the
//   BEGIN_COM_MAP / COM_INTERFACE_ENTRY* / END_COM_MAP macro family.
// TODO(macos): no replacement for the embedded IE browser is planned.
#ifndef _WIN32

#include "windows.h"
#include "objbase.h"
#include "atlbase.h"     // CComModule / CComPtr (already shimmed)

// Threading model tags (no actual locking needed for the compile-only path).
class CComSingleThreadModel {};
class CComMultiThreadModel  {};

// CComObjectRootEx: base providing the ref-count plumbing for an ATL object.
template <class ThreadModel = CComSingleThreadModel>
class CComObjectRootEx
{
public:
    CComObjectRootEx() : m_dwRef(0) {}
    ULONG InternalAddRef()  { return ++m_dwRef; }
    ULONG InternalRelease() { return --m_dwRef; }
    HRESULT _InternalQueryInterface(REFIID, void**) { return E_NOINTERFACE; }
protected:
    ULONG m_dwRef;
};

// CComCoClass: class-factory base. Empty here (objects are never registered).
template <class T, const GUID* pclsid = nullptr>
class CComCoClass {};

// CComObject<T>: concrete instantiable wrapper around an ATL object T.
template <class Base>
class CComObject : public Base
{
public:
    CComObject() {}
    // CreateInstance: stubbed to fail (the browser object is never created on
    // macOS). Returns E_NOTIMPL and a null out-pointer.
    static HRESULT CreateInstance(CComObject<Base>** pp)
    { if (pp) *pp = nullptr; return E_NOTIMPL; }
};

// COM map macros. On Windows these build an interface-entry table consumed by
// the ATL QueryInterface machinery. Here the QI path is dead, so the macros
// expand to a no-op _InternalQueryInterface override that reports no interface.
#ifndef BEGIN_COM_MAP
#define BEGIN_COM_MAP(x) \
    public: \
        HRESULT _InternalQueryInterface(REFIID iid, void** ppvObject) { \
            (void)iid; if (ppvObject) *ppvObject = nullptr; return E_NOINTERFACE;
#define COM_INTERFACE_ENTRY(x)
#define COM_INTERFACE_ENTRY2(x, x2)
#define COM_INTERFACE_ENTRY_IID(iid, x)
#define COM_INTERFACE_ENTRY_AGGREGATE(iid, punk)
#define END_COM_MAP() \
        }
#endif

#ifndef DECLARE_NOT_AGGREGATABLE
#define DECLARE_NOT_AGGREGATABLE(x)
#endif
#ifndef DECLARE_PROTECT_FINAL_CONSTRUCT
#define DECLARE_PROTECT_FINAL_CONSTRUCT()
#endif
#ifndef DECLARE_REGISTRY_RESOURCEID
#define DECLARE_REGISTRY_RESOURCEID(x)
#endif

#endif // !_WIN32
