#pragma once
// <direct.h> shim -> POSIX directory functions.
#ifndef _WIN32
#include <sys/stat.h>
#include <unistd.h>

// TheSuperHackers @port macOS — normalise `\`-separated engine paths to POSIX
// (shared helper; see win32_api.h). Keeps _mkdir/_rmdir/_chdir consistent with
// the fopen call sites so directory create/remove/cd all hit the same on-disk
// path. Guarded so multiple compat headers can define it in one TU.
#ifndef OSDEP_COMPAT_NP_DEFINED
#define OSDEP_COMPAT_NP_DEFINED
#if defined(__APPLE__)
#include "apple_path_shim.h"
namespace osdep_compat_detail {
  inline const char* np(const char* p)  { return p ? ::apple_path::normalize(p)   : p; }
  inline const char* npb(const char* p) { return p ? ::apple_path::normalize_b(p) : p; }
}
#else
namespace osdep_compat_detail {
  inline const char* np(const char* p)  { return p; }
  inline const char* npb(const char* p) { return p; }
}
#endif
#endif // OSDEP_COMPAT_NP_DEFINED

inline int _mkdir(const char* p) { return ::mkdir(osdep_compat_detail::np(p), 0777); }
inline int _rmdir(const char* p) { return ::rmdir(osdep_compat_detail::np(p)); }
inline int _chdir(const char* p) { return ::chdir(osdep_compat_detail::np(p)); }
inline char* _getcwd(char* buf, int size) { return ::getcwd(buf, size); }
#endif
