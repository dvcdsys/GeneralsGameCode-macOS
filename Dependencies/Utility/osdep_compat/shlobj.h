#pragma once
// <shlobj.h> shim for non-Windows builds.
//
// Shell folder path queries (where to put user docs / save games). Mapped onto
// the POSIX home directory so the engine can find a writable location.
// TODO(macos): use NSSearchPathForDirectoriesInDomains for the canonical
// ~/Documents and ~/Library/Application Support locations.
#ifndef _WIN32

#include "windows.h"
#include "shellapi.h"
#include <pwd.h>

// CSIDL_* special-folder identifiers (only the few the engine asks for).
#ifndef CSIDL_PERSONAL
#define CSIDL_DESKTOP          0x0000
#define CSIDL_PERSONAL         0x0005  // "My Documents"
#define CSIDL_APPDATA          0x001A
#define CSIDL_LOCAL_APPDATA    0x001C
#define CSIDL_DESKTOPDIRECTORY 0x0010
#define CSIDL_MYDOCUMENTS      0x000C
#define CSIDL_PROFILE          0x0028
#define CSIDL_FLAG_CREATE      0x8000
#endif

#ifndef SHGFP_TYPE_CURRENT
#define SHGFP_TYPE_CURRENT 0
#define SHGFP_TYPE_DEFAULT 1
#endif

// KNOWNFOLDERID (Vista+ SHGetKnownFolderPath). The engine resolves
// SHGetKnownFolderPath dynamically and guards the call with a null check, so on
// macOS the pointer is null and this path is skipped at runtime; the symbols
// only need to exist for compilation.
#ifndef _KNOWNFOLDERID_DEFINED
#define _KNOWNFOLDERID_DEFINED
typedef GUID KNOWNFOLDERID;
typedef const KNOWNFOLDERID& REFKNOWNFOLDERID;
typedef WCHAR* PWSTR;
typedef const WCHAR* PCWSTR;
// FOLDERID_Documents {FDD39AD0-238F-46AF-ADB4-6C85480369C7}
static const KNOWNFOLDERID FOLDERID_Documents =
    { 0xFDD39AD0, 0x238F, 0x46AF, { 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 } };
#define KF_FLAG_DEFAULT       0x00000000u
#define KF_FLAG_CREATE        0x00008000u
#define KF_FLAG_DONT_VERIFY   0x00004000u
#endif

// LPITEMIDLIST / ITEMIDLIST: shell namespace identifiers, referenced only as an
// opaque pointer by the shell-folder code. TODO(macos): no shell namespace.
#ifndef _LPITEMIDLIST_DEFINED
#define _LPITEMIDLIST_DEFINED
typedef struct _ITEMIDLIST { unsigned short cb; } ITEMIDLIST, *LPITEMIDLIST, *PIDLIST_ABSOLUTE;
typedef const struct _ITEMIDLIST* LPCITEMIDLIST;
#endif

inline const char *_macHomeDir()
{
  const char *home = ::getenv("HOME");
  if (home && *home) return home;
  struct passwd *pw = ::getpwuid(::getuid());
  return (pw && pw->pw_dir) ? pw->pw_dir : "/tmp";
}

// SHGetSpecialFolderPath: write the resolved path into `path`. Returns TRUE.
inline BOOL SHGetSpecialFolderPathA(HWND, char *path, int csidl, BOOL /*create*/)
{
  if (!path) return FALSE;
  const char *home = _macHomeDir();
  switch (csidl & ~CSIDL_FLAG_CREATE) {
    case CSIDL_PERSONAL:
    case CSIDL_MYDOCUMENTS:
      ::snprintf(path, MAX_PATH, "%s/Documents", home); break;
    case CSIDL_APPDATA:
    case CSIDL_LOCAL_APPDATA:
      ::snprintf(path, MAX_PATH, "%s/Library/Application Support", home); break;
    case CSIDL_DESKTOP:
    case CSIDL_DESKTOPDIRECTORY:
      ::snprintf(path, MAX_PATH, "%s/Desktop", home); break;
    default:
      ::snprintf(path, MAX_PATH, "%s", home); break;
  }
  return TRUE;
}
inline BOOL SHGetSpecialFolderPath(HWND h, char *path, int csidl, BOOL create)
{ return SHGetSpecialFolderPathA(h, path, csidl, create); }

// SHGetFolderPath: newer API, same behaviour. Returns S_OK (0).
inline HRESULT SHGetFolderPathA(HWND h, int csidl, HANDLE /*token*/, DWORD /*flags*/, char *path)
{ return SHGetSpecialFolderPathA(h, path, csidl, TRUE) ? 0 : E_FAIL; }
inline HRESULT SHGetFolderPath(HWND h, int csidl, HANDLE token, DWORD flags, char *path)
{ return SHGetFolderPathA(h, csidl, token, flags, path); }

// PIDL-based folder API (ReplayMenu uses it to resolve the Desktop path). We
// stash the CSIDL in the returned PIDL token and resolve it in
// SHGetPathFromIDList via SHGetSpecialFolderPathA.
inline HRESULT SHGetSpecialFolderLocation(HWND, int csidl, LPITEMIDLIST *ppidl)
{
  if (ppidl) *ppidl = (LPITEMIDLIST)(uintptr_t)(unsigned)csidl;
  return 0;
}
inline BOOL SHGetPathFromIDList(LPITEMIDLIST pidl, char *path)
{
  int csidl = (int)(uintptr_t)pidl;
  return SHGetSpecialFolderPathA(nullptr, path, csidl, FALSE);
}
inline BOOL SHGetPathFromIDListA(LPITEMIDLIST pidl, char *path) { return SHGetPathFromIDList(pidl, path); }

#endif // !_WIN32
