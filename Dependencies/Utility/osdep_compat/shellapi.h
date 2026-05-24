#pragma once
// <shellapi.h> shim for non-Windows builds.
//
// ShellExecute / ShellExecuteEx (launch a URL or external app), Shell_NotifyIcon
// (tray icon). All stubbed: there is no Windows shell on macOS. ShellExecute of a
// URL could later be wired to `open <url>` via NSWorkspace, but for now it is a
// no-op so the engine compiles.
// TODO(macos): route URL/file "open" verbs to NSWorkspace/`open`.
#ifndef _WIN32

#include "windows.h"

// ShowWindow nCmdShow values (also used by ShellExecute).
#ifndef SW_HIDE
#define SW_HIDE             0
#define SW_SHOWNORMAL       1
#define SW_NORMAL           1
#define SW_SHOWMINIMIZED    2
#define SW_SHOWMAXIMIZED    3
#define SW_MAXIMIZE         3
#define SW_SHOWNOACTIVATE   4
#define SW_SHOW             5
#define SW_MINIMIZE         6
#define SW_SHOWMINNOACTIVE  7
#define SW_SHOWNA           8
#define SW_RESTORE          9
#define SW_SHOWDEFAULT      10
#endif

// ShellExecuteEx fMask flags.
#ifndef SEE_MASK_NOCLOSEPROCESS
#define SEE_MASK_DEFAULT        0x00000000
#define SEE_MASK_NOCLOSEPROCESS 0x00000040
#define SEE_MASK_FLAG_NO_UI     0x00000400
#endif

typedef struct _SHELLEXECUTEINFOA {
  DWORD     cbSize;
  ULONG     fMask;
  HWND      hwnd;
  const char *lpVerb;
  const char *lpFile;
  const char *lpParameters;
  const char *lpDirectory;
  int       nShow;
  HINSTANCE hInstApp;
  void *    lpIDList;
  const char *lpClass;
  HKEY      hkeyClass;
  DWORD     dwHotKey;
  HANDLE    hIcon;
  HANDLE    hProcess;
} SHELLEXECUTEINFOA, *LPSHELLEXECUTEINFOA;
typedef SHELLEXECUTEINFOA SHELLEXECUTEINFO;
typedef LPSHELLEXECUTEINFOA LPSHELLEXECUTEINFO;

// ShellExecute returns a "fake" HINSTANCE > 32 to indicate success on Windows.
inline HINSTANCE ShellExecuteA(HWND, const char * /*verb*/, const char * /*file*/,
                               const char * /*params*/, const char * /*dir*/, int /*show*/)
{ return (HINSTANCE)(intptr_t)33; } // TODO(macos): NSWorkspace open
inline HINSTANCE ShellExecute(HWND h, const char *v, const char *f,
                              const char *p, const char *d, int s)
{ return ShellExecuteA(h, v, f, p, d, s); }

inline BOOL ShellExecuteExA(SHELLEXECUTEINFOA *info)
{ if (info) { info->hInstApp = (HINSTANCE)(intptr_t)33; info->hProcess = nullptr; } return TRUE; }
inline BOOL ShellExecuteEx(SHELLEXECUTEINFO *info) { return ShellExecuteExA(info); }

// Notification (tray) icon: no-op.
typedef struct _NOTIFYICONDATAA { DWORD cbSize; HWND hWnd; UINT uID; UINT uFlags; } NOTIFYICONDATAA, *PNOTIFYICONDATAA, NOTIFYICONDATA, *PNOTIFYICONDATA;
#ifndef NIM_ADD
#define NIM_ADD    0x00000000
#define NIM_MODIFY 0x00000001
#define NIM_DELETE 0x00000002
#endif
inline BOOL Shell_NotifyIconA(DWORD /*msg*/, NOTIFYICONDATAA * /*data*/) { return TRUE; }
inline BOOL Shell_NotifyIcon(DWORD msg, NOTIFYICONDATA *data) { return Shell_NotifyIconA(msg, data); }

#endif // !_WIN32
