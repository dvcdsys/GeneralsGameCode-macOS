#pragma once
// Minimal <mbstring.h> (MSVC multibyte-string CRT) shim for non-Windows builds.
// The engine's IME (input-method) code uses a couple of multibyte helpers. The
// IME path is a runtime-input gap on macOS (no IME wired up yet); these only
// have to compile and behave reasonably for plain ASCII.
// TODO(macos): real multibyte/IME handling arrives with the SDL input phase.
#ifndef _WIN32

#include <cstring>

// _mbsnccnt: count of multibyte *characters* in the first `count` bytes. For an
// ASCII/single-byte string this is just min(strlen, count).
inline size_t _mbsnccnt(const unsigned char* s, size_t count)
{
    if (!s) return 0;
    size_t n = 0;
    while (n < count && s[n]) ++n;
    return n;
}
// _mbslen / _mbclen / _mbsinc: ASCII-equivalent fallbacks.
inline size_t _mbslen(const unsigned char* s) { return s ? ::strlen((const char*)s) : 0; }
inline size_t _mbclen(const unsigned char* /*s*/) { return 1; }
inline unsigned char* _mbsinc(const unsigned char* s) { return (unsigned char*)(s + 1); }

#endif // !_WIN32
