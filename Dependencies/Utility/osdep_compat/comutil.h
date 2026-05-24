#pragma once
// Minimal <comutil.h> shim for non-Windows builds. Provides just `_bstr_t`,
// the COM BSTR wrapper, as used by the WOL embedded-browser code (FEBDispatch).
// TODO(macos): the embedded IE browser is Windows-only; no replacement planned.
#ifndef _WIN32

#include "windows.h"
#include <string>
#include <vector>

// _bstr_t: thin wrapper around a wide string. Constructed from a narrow string;
// implicitly convertible to both narrow and wide C strings so it can be passed
// to the LoadTypeLib overloads in oleauto.h.
class _bstr_t
{
public:
    _bstr_t() {}
    _bstr_t(const char* s) { if (s) { m_narrow = s; m_wide.assign(s, s + m_narrow.size()); m_wide.push_back(0); } else m_wide.push_back(0); }
    _bstr_t(const wchar_t* s) { if (s) { while (*s) { m_wide.push_back((WCHAR)*s); m_narrow.push_back((char)*s); ++s; } } m_wide.push_back(0); }

    operator const char*() const   { return m_narrow.c_str(); }
    operator const WCHAR*() const  { return m_wide.empty() ? nullptr : m_wide.data(); }
    size_t length() const          { return m_narrow.size(); }

private:
    std::string        m_narrow;
    std::vector<WCHAR> m_wide;
};

#endif // !_WIN32
