/*
**	Apple path-normalisation shim — header-only, Apple-only.
**
**	Engine code constructs many file paths with Windows separators
**	(`data\Scripts\foo`) and passes them directly to POSIX `fopen` /
**	`remove` / `rename`, bypassing `TheFileSystem`. On macOS those calls
**	then fail silently because POSIX treats `\` as part of the filename.
**
**	Win32LocalFileSystem already normalises in its `openFile` path, but
**	a long tail of direct-fopen sites (UserPreferences, XferSave/Load,
**	Debug log, GameSpy config, MapUtil, Image, Recorder…) skip that
**	layer. Wrapping the three call entry points here lets every engine
**	translation unit that pulls in `<windows.h>` (which is all of them
**	via PreRTS.h) get the fix for free, with zero engine-code churn.
**
**	The override is a textual macro that expands at the call site. It
**	must be included AFTER `<cstdio>` / `<stdio.h>` so the real
**	function declarations are visible — which is why it lives at the
**	bottom of `windows.h`, where the standard headers have already
**	been processed via PreRTS.h's earlier includes.
**
**	Pure POSIX implementation: no `std::filesystem` dependency, since
**	not every engine translation unit is compiled with C++17 filesystem
**	support enabled.
**
**	No-op on Windows builds (entire file is `#if defined(__APPLE__)`).
*/

#pragma once

#if defined(__APPLE__)

#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <dirent.h>
#include <strings.h>   // strcasecmp

namespace apple_path {

inline bool _exists(const char* p)
{
    struct stat st;
    return ::stat(p, &st) == 0;
}

// Append `comp` to `out` with `/` separator (avoiding a leading `/` if
// `out` is empty or already ends in `/`).
inline void _append(std::string& out, const char* comp)
{
    if (!out.empty() && out.back() != '/')
        out.push_back('/');
    out.append(comp);
}

// Returns:
//   - the original pointer if the path has no `\` separator, so the
//     common (already-POSIX) case has zero allocation overhead;
//   - else a pointer into `out` with the path slash-corrected and (if
//     possible) case-corrected component-by-component.
inline const char* _normalize_impl(const char* path, std::string& out)
{
    if (!path || !*path)
        return path;

    if (std::strchr(path, '\\') == nullptr)
        return path;

    // Backslash → slash.
    std::string s(path);
    for (char& c : s)
        if (c == '\\') c = '/';

    if (_exists(s.c_str()))
    {
        out = std::move(s);
        return out.c_str();
    }

    // Walk component-by-component. For each component, prefer the
    // literal match; fall back to case-insensitive directory scan.
    // If a parent component doesn't resolve, return the cleaned path
    // unchanged so a caller doing fopen("w") can still create the file.
    out.clear();
    out.reserve(s.size());

    const bool absolute = !s.empty() && s[0] == '/';
    std::string token;
    size_t pos = absolute ? 1 : 0;
    if (absolute)
        out.push_back('/');

    while (pos <= s.size())
    {
        if (pos == s.size() || s[pos] == '/')
        {
            if (!token.empty())
            {
                // Try literal first.
                std::string candidate = out;
                _append(candidate, token.c_str());
                if (_exists(candidate.c_str()))
                {
                    out = std::move(candidate);
                }
                else
                {
                    // Case-insensitive scan of parent directory.
                    const char* parent = out.empty() ? "." : out.c_str();
                    DIR* d = ::opendir(parent);
                    bool matched = false;
                    if (d)
                    {
                        struct dirent* e;
                        while ((e = ::readdir(d)) != nullptr)
                        {
                            if (::strcasecmp(e->d_name, token.c_str()) == 0)
                            {
                                _append(out, e->d_name);
                                matched = true;
                                break;
                            }
                        }
                        ::closedir(d);
                    }
                    if (!matched)
                    {
                        // Append remaining path verbatim (slash-fixed)
                        // so create-mode fopen still has a usable path.
                        _append(out, token.c_str());
                        if (pos < s.size())
                            out.append(s.c_str() + pos);
                        return out.c_str();
                    }
                }
                token.clear();
            }
            ++pos;
        }
        else
        {
            token.push_back(s[pos++]);
        }
    }

    return out.c_str();
}

// Single-slot thread-local buffer. Suitable for any call that takes one
// path argument (fopen, remove, open, access, …). The returned C string
// is valid until the next call to `normalize()` on this thread.
inline const char* normalize(const char* path)
{
    thread_local std::string buf;
    return _normalize_impl(path, buf);
}

// Second slot for two-path calls (rename, link). Independent buffer so
// the first argument is not clobbered by the second.
inline const char* normalize_b(const char* path)
{
    thread_local std::string buf;
    return _normalize_impl(path, buf);
}

}  // namespace apple_path

// IMPORTANT: NO macro override here. Earlier revisions hijacked
// `fopen` / `remove` / `rename` via #define so engine code did not need
// touching — but C++ STL/MFC/ATL classes also expose member functions
// with those names (libc++ fstream has a private `fopen` helper;
// `std::set::erase_if` calls a `remove`; etc). A textual macro
// rewrites those too and breaks the standard library.
//
// Instead, expose `apple_path::normalize()` as a helper. Call sites
// that pass Windows-style paths to bare `fopen` / `remove` / `rename`
// — UserPreferences, XferSave/Load, Debug.cpp, MainMenuUtils, MapUtil,
// Image, Recorder, GlobalData::BuildUserDataPathFromRegistry, …
// wrap the path argument explicitly under `#if defined(__APPLE__)`.

#endif  // __APPLE__
