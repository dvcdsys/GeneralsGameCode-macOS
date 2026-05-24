#pragma once
// <wininet.h> shim for non-Windows builds.
//
// WinINet HTTP/FTP client API. Online auto-patch / news features are dead on
// macOS for now, so every call fails gracefully (returns NULL/FALSE).
// TODO(macos): a real impl would use NSURLSession / libcurl.
#ifndef _WIN32

#include "windows.h"

typedef void *HINTERNET;

#ifndef INTERNET_OPEN_TYPE_DIRECT
#define INTERNET_OPEN_TYPE_PRECONFIG 0
#define INTERNET_OPEN_TYPE_DIRECT    1
#define INTERNET_OPEN_TYPE_PROXY     3
#endif
#ifndef INTERNET_FLAG_RELOAD
#define INTERNET_FLAG_RELOAD         0x80000000
#define INTERNET_FLAG_NO_CACHE_WRITE 0x04000000
#endif
#ifndef INTERNET_SERVICE_FTP
#define INTERNET_SERVICE_FTP  1
#define INTERNET_SERVICE_HTTP 3
#endif

inline HINTERNET InternetOpenA(const char *, DWORD, const char *, const char *, DWORD) { return nullptr; }
inline HINTERNET InternetOpen(const char *a, DWORD b, const char *c, const char *d, DWORD e)
{ return InternetOpenA(a, b, c, d, e); }
inline HINTERNET InternetOpenUrlA(HINTERNET, const char *, const char *, DWORD, DWORD, DWORD_PTR) { return nullptr; }
inline HINTERNET InternetConnectA(HINTERNET, const char *, WORD, const char *, const char *, DWORD, DWORD, DWORD_PTR) { return nullptr; }
inline BOOL      InternetReadFile(HINTERNET, void *, DWORD, DWORD *bytesRead) { if (bytesRead) *bytesRead = 0; return FALSE; }
inline BOOL      InternetCloseHandle(HINTERNET) { return TRUE; }

#endif // !_WIN32
