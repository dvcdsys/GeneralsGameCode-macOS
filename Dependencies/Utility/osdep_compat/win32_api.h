#pragma once

// ---------------------------------------------------------------------------
// POSIX-backed shims for the Win32 *API functions* used by the debug/ and
// profile/ diagnostic libraries on macOS / Linux.
//
// This is intentionally header-only (inline) so no extra .cpp / CMake wiring
// is needed. It is pulled in near the end of <windows.h> (the type-vocabulary
// shim) and is guarded so it never touches the real Windows SDK.
//
// These are DIAGNOSTIC subsystems: behavioural fidelity matters far less than
// "compiles and does not crash". Anything that has no sane POSIX analogue is
// stubbed to a benign default and marked with TODO(macos).
// ---------------------------------------------------------------------------

#ifndef _WIN32

#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <unistd.h>
#include <fcntl.h>
#include <ctime>
#include <sys/stat.h>
#include <dirent.h>       // opendir/readdir/closedir (FindFirstFile family)
#include <fnmatch.h>      // fnmatch (glob matching for FindFirstFile)
#include <pthread.h>      // pthread_create (CreateThread)
#include <limits.h>       // PATH_MAX
#include <string>         // std::string (find-handle bookkeeping)

// COLORREF (0x00bbggrr) used by the GDI text stubs below.
#ifndef _COLORREF_DEFINED
#define _COLORREF_DEFINED
typedef DWORD COLORREF;
#ifndef RGB
#define RGB(r,g,b) ((COLORREF)(((BYTE)(r))|(((WORD)((BYTE)(g)))<<8)|(((DWORD)(BYTE)(b))<<16)))
#endif
#endif

#if defined(__APPLE__)
#include <malloc/malloc.h>       // malloc_size
#include <mach/mach_time.h>      // mach_absolute_time, mach_timebase_info
#include <mach-o/dyld.h>         // _NSGetExecutablePath
#endif

// ---------------------------------------------------------------------------
// TheSuperHackers @port macOS — path normalisation for the POSIX-backed
// filesystem shims below (CreateDirectory, SetCurrentDirectory,
// GetFileAttributes, DeleteFile, CreateFile, CopyFile).
//
// Engine code hands these Win32 APIs paths built with `\` separators — e.g.
// GameState::getSaveDirectory() returns ".../Data/Save\". Bare mkdir/chdir/
// stat/unlink/open treat `\` as an ordinary filename character, so the engine
// creates a directory literally named `Save\` while the fopen call sites (which
// already run apple_path::normalize) open `Save/00000000.sav` — a mismatch that
// makes Save/Load silently fail (the file's parent directory never exists).
// Route every path-taking shim through the SAME apple_path::normalize() the
// fopen sites use so both halves agree on the on-disk path.
//
// `np` uses one thread-local slot, `npb` a second, so two-path calls (CopyFile)
// don't clobber each other. Guarded so io.h can reuse it without redefinition.
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// File-handle model.
//
// A Win32 file HANDLE is modelled as (HANDLE)(intptr_t)(fd + 1) so that a
// valid fd of 0 (stdin) is distinguishable from a NULL handle, and
// INVALID_HANDLE_VALUE is (HANDLE)-1 exactly as on Windows.
// ---------------------------------------------------------------------------
#ifndef INVALID_HANDLE_VALUE
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#endif

namespace osdep_compat_detail {
  inline int handle_to_fd(HANDLE h) { return (int)((intptr_t)h) - 1; }
  inline HANDLE fd_to_handle(int fd) { return (HANDLE)(intptr_t)(fd + 1); }
}

// ---------------------------------------------------------------------------
// CreateFile flags. Standard Win32 numeric values where they matter; the
// access bits are mapped to POSIX open() modes inside CreateFile().
// ---------------------------------------------------------------------------
#ifndef GENERIC_READ
#define GENERIC_READ              0x80000000u
#endif
#ifndef GENERIC_WRITE
#define GENERIC_WRITE             0x40000000u
#endif
#ifndef CREATE_ALWAYS
#define CREATE_ALWAYS             2
#endif
#ifndef OPEN_EXISTING
#define OPEN_EXISTING             3
#endif
#ifndef FILE_ATTRIBUTE_NORMAL
#define FILE_ATTRIBUTE_NORMAL     0x00000080u
#endif
#ifndef FILE_FLAG_WRITE_THROUGH
#define FILE_FLAG_WRITE_THROUGH   0x80000000u
#endif
#ifndef ERROR_FILE_EXISTS
#define ERROR_FILE_EXISTS         80
#endif
// Win32 system error codes referenced by device-layer error handling.
#ifndef ERROR_BUSY
#define ERROR_BUSY                170L
#endif
#ifndef ERROR_READ_FAULT
#define ERROR_READ_FAULT          30L
#endif
#ifndef ERROR_BAD_DRIVER_LEVEL
#define ERROR_BAD_DRIVER_LEVEL    119L
#endif
#ifndef ERROR_ALREADY_INITIALIZED
#define ERROR_ALREADY_INITIALIZED 1247L
#endif
#ifndef ERROR_RMODE_APP
#define ERROR_RMODE_APP           196L
#endif
#ifndef ERROR_NOT_ENOUGH_MEMORY
#define ERROR_NOT_ENOUGH_MEMORY   8L
#endif
#ifndef ERROR_INVALID_PARAMETER
#define ERROR_INVALID_PARAMETER   87L
#endif
#ifndef ERROR_NOT_READY
#define ERROR_NOT_READY           21L
#endif
#ifndef ERROR_INVALID_ACCESS
#define ERROR_INVALID_ACCESS      12L
#endif
#ifndef ERROR_OLD_WIN_VERSION
#define ERROR_OLD_WIN_VERSION     1150L
#endif

inline HANDLE CreateFile(const char *fileName, DWORD desiredAccess,
                         DWORD /*shareMode*/, void * /*securityAttrs*/,
                         DWORD creationDisposition, DWORD /*flagsAndAttrs*/,
                         HANDLE /*templateFile*/)
{
  // Named pipes (\\machine\pipe\...) are the remote-debugger transport and
  // have no POSIX equivalent here -> always fail. See debug_io_net.cpp.
  if (fileName && (fileName[0] == '\\' || fileName[0] == '/') &&
      (fileName[1] == '\\' || fileName[1] == '/'))
    return INVALID_HANDLE_VALUE;

  int flags = 0;
  const bool wantRead  = (desiredAccess & GENERIC_READ) != 0;
  const bool wantWrite = (desiredAccess & GENERIC_WRITE) != 0;
  if (wantRead && wantWrite)      flags = O_RDWR;
  else if (wantWrite)             flags = O_WRONLY;
  else                            flags = O_RDONLY;

  if (creationDisposition == CREATE_ALWAYS)
    flags |= O_CREAT | O_TRUNC;
  // OPEN_EXISTING -> no extra flags.

  int fd = ::open(osdep_compat_detail::np(fileName), flags, 0644);
  if (fd < 0)
    return INVALID_HANDLE_VALUE;
  return osdep_compat_detail::fd_to_handle(fd);
}

inline BOOL ReadFile(HANDLE h, void *buffer, DWORD numBytes,
                     DWORD *numRead, void * /*overlapped*/)
{
  if (h == INVALID_HANDLE_VALUE) { if (numRead) *numRead = 0; return FALSE; }
  ssize_t n = ::read(osdep_compat_detail::handle_to_fd(h), buffer, numBytes);
  if (n < 0) { if (numRead) *numRead = 0; return FALSE; }
  if (numRead) *numRead = (DWORD)n;
  return TRUE;
}

inline BOOL WriteFile(HANDLE h, const void *buffer, DWORD numBytes,
                      DWORD *numWritten, void * /*overlapped*/)
{
  if (h == INVALID_HANDLE_VALUE) { if (numWritten) *numWritten = 0; return FALSE; }
  ssize_t n = ::write(osdep_compat_detail::handle_to_fd(h), buffer, numBytes);
  if (n < 0) { if (numWritten) *numWritten = 0; return FALSE; }
  if (numWritten) *numWritten = (DWORD)n;
  return TRUE;
}

// Forward-declared so CloseHandle can dispose of event/thread sync objects.
// (The SyncObject machinery is defined further down in this header.)
namespace osdep_compat_detail {
  struct SyncObject;
  bool sync_is_object(HANDLE h);
  void sync_close(SyncObject *o);
}

inline BOOL CloseHandle(HANDLE h)
{
  if (h == INVALID_HANDLE_VALUE || h == nullptr)
    return FALSE;
  // Event / thread objects are heap-allocated SyncObjects.
  if (osdep_compat_detail::sync_is_object(h)) {
    osdep_compat_detail::sync_close((osdep_compat_detail::SyncObject *)h);
    return TRUE;
  }
  // Don't close the std handles backed by fd 0/1/2.
  int fd = osdep_compat_detail::handle_to_fd(h);
  if (fd <= 2)
    return TRUE;
  return ::close(fd) == 0 ? TRUE : FALSE;
}

// TODO(macos): real file copy. Used only by the log-file "copy" command.
inline BOOL CopyFile(const char *existing, const char *newFile, BOOL failIfExists)
{
  if (failIfExists) {
    int fd = ::open(osdep_compat_detail::npb(newFile), O_RDONLY);
    if (fd >= 0) { ::close(fd); errno = 0; return FALSE; } // pretend ERROR_FILE_EXISTS
  }
  int in = ::open(osdep_compat_detail::np(existing), O_RDONLY);
  if (in < 0) return FALSE;
  int out = ::open(osdep_compat_detail::npb(newFile), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (out < 0) { ::close(in); return FALSE; }
  char buf[8192];
  ssize_t n;
  BOOL ok = TRUE;
  while ((n = ::read(in, buf, sizeof(buf))) > 0)
    if (::write(out, buf, (size_t)n) != n) { ok = FALSE; break; }
  if (n < 0) ok = FALSE;
  ::close(in);
  ::close(out);
  return ok;
}

// ---------------------------------------------------------------------------
// Global memory -> malloc/free/realloc. GlobalSize uses malloc_size on macOS.
// ---------------------------------------------------------------------------
#ifndef GMEM_FIXED
#define GMEM_FIXED   0x0000
#endif
#ifndef GMEM_MOVEABLE
#define GMEM_MOVEABLE 0x0002
#endif

inline HGLOBAL GlobalAlloc(unsigned /*flags*/, size_t numBytes)
{
  return (HGLOBAL)::malloc(numBytes ? numBytes : 1);
}
inline HGLOBAL GlobalReAlloc(HGLOBAL mem, size_t newSize, unsigned /*flags*/)
{
  return (HGLOBAL)::realloc((void *)mem, newSize ? newSize : 1);
}
inline HGLOBAL GlobalFree(HGLOBAL mem)
{
  ::free((void *)mem);
  return nullptr;
}
inline size_t GlobalSize(HGLOBAL mem)
{
  if (!mem) return 0;
#if defined(__APPLE__)
  return ::malloc_size((const void *)mem);
#else
  return 0; // TODO(macos): only used to size a memcpy on a realloc fallback path.
#endif
}

// ---------------------------------------------------------------------------
// High-resolution timers -> mach_absolute_time.
// QueryPerformanceCounter returns ticks; QueryPerformanceFrequency the rate.
// We expose nanoseconds: counter = ns, frequency = 1e9.
// ---------------------------------------------------------------------------
inline BOOL QueryPerformanceFrequency(LARGE_INTEGER *freq)
{
  if (freq) freq->QuadPart = 1000000000LL; // ns
  return TRUE;
}
inline BOOL QueryPerformanceCounter(LARGE_INTEGER *counter)
{
  if (!counter) return FALSE;
#if defined(__APPLE__)
  static mach_timebase_info_data_t tb = {0, 0};
  if (tb.denom == 0) mach_timebase_info(&tb);
  uint64_t t = mach_absolute_time();
  counter->QuadPart = (int64_t)((t * tb.numer) / tb.denom); // ns
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  counter->QuadPart = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
  return TRUE;
}

// ---------------------------------------------------------------------------
// Process / module helpers.
// ---------------------------------------------------------------------------
inline HANDLE GetCurrentProcess()        { return (HANDLE)(intptr_t)-1; }
inline HANDLE GetCurrentThread()         { return (HANDLE)(intptr_t)-2; }
inline DWORD  GetCurrentProcessId()      { return (DWORD)::getpid(); }
inline DWORD  GetLastError()             { return (DWORD)errno; }
inline BOOL   TerminateProcess(HANDLE /*proc*/, unsigned exitCode)
{
  ::_exit((int)exitCode);
  return TRUE;
}

inline DWORD GetModuleFileName(HMODULE /*module*/, char *out, DWORD size)
{
  if (!out || !size) return 0;
#if defined(__APPLE__)
  uint32_t bufSize = (uint32_t)size;
  if (_NSGetExecutablePath(out, &bufSize) != 0) { out[0] = 0; return 0; }
  out[size - 1] = 0;
  return (DWORD)::strlen(out);
#else
  ssize_t n = ::readlink("/proc/self/exe", out, size - 1);
  if (n < 0) { out[0] = 0; return 0; }
  out[n] = 0;
  return (DWORD)n;
#endif
}

inline BOOL GetComputerName(char *out, DWORD *size)
{
  if (!out || !size) return FALSE;
  if (::gethostname(out, *size) != 0) { out[0] = 0; return FALSE; }
  out[*size - 1] = 0;
  *size = (DWORD)::strlen(out);
  return TRUE;
}
inline BOOL GetUserName(char *out, DWORD *size)
{
  if (!out || !size) return FALSE;
  const char *u = ::getenv("USER");
  if (!u) u = "user";
  ::strncpy(out, u, *size);
  out[*size - 1] = 0;
  *size = (DWORD)::strlen(out);
  return TRUE;
}

inline void GetLocalTime(SYSTEMTIME *st)
{
  if (!st) return;
  time_t t = ::time(nullptr);
  struct tm lt;
  ::localtime_r(&t, &lt);
  st->wYear         = (WORD)(lt.tm_year + 1900);
  st->wMonth        = (WORD)(lt.tm_mon + 1);
  st->wDayOfWeek    = (WORD)lt.tm_wday;
  st->wDay          = (WORD)lt.tm_mday;
  st->wHour         = (WORD)lt.tm_hour;
  st->wMinute       = (WORD)lt.tm_min;
  st->wSecond       = (WORD)lt.tm_sec;
  st->wMilliseconds = 0;
}

// Structured-exception (SEH) crash context. There is no SEH on POSIX; the crash
// dumper reads these fields but the dump path is never reached on macOS (the
// filter installed via SetUnhandledExceptionFilter is never invoked). Defined
// here (rather than in imagehlp.h) because windows.h always pulls in this header
// but not imagehlp.h, and WinMain.cpp dereferences EXCEPTION_POINTERS.
#ifndef _EXCEPTION_RECORD_DEFINED
#define _EXCEPTION_RECORD_DEFINED
#define EXCEPTION_MAXIMUM_PARAMETERS 15
typedef struct _EXCEPTION_RECORD {
  DWORD     ExceptionCode;
  DWORD     ExceptionFlags;
  struct _EXCEPTION_RECORD *ExceptionRecord;
  void     *ExceptionAddress;
  DWORD     NumberParameters;
  uintptr_t ExceptionInformation[EXCEPTION_MAXIMUM_PARAMETERS];
} EXCEPTION_RECORD, *PEXCEPTION_RECORD;
struct _CONTEXT; // full def in imagehlp.h; only used here as a pointer member.
typedef struct _EXCEPTION_POINTERS {
  PEXCEPTION_RECORD ExceptionRecord;
  struct _CONTEXT  *ContextRecord;
} EXCEPTION_POINTERS, *PEXCEPTION_POINTERS, *LPEXCEPTION_POINTERS;
#endif
#ifndef EXCEPTION_EXECUTE_HANDLER
#define EXCEPTION_EXECUTE_HANDLER     1
#define EXCEPTION_CONTINUE_SEARCH     0
#define EXCEPTION_CONTINUE_EXECUTION (-1)
#endif

// SetUnhandledExceptionFilter: no SEH on POSIX -> no-op. Returns previous (none).
// Different callers declare the filter with subtly different return types
// (debug/ uses "long __stdcall"; WinMain.cpp uses "LONG WINAPI", and on LP64
// macOS LONG==int != long). Accept any filter pointer via a template so all
// spellings bind without a cast; the filter is never invoked here anyway.
typedef LONG (*LPTOP_LEVEL_EXCEPTION_FILTER)(struct _EXCEPTION_POINTERS *);
template <typename FilterFn>
inline LPTOP_LEVEL_EXCEPTION_FILTER SetUnhandledExceptionFilter(FilterFn /*filter*/)
{
  return nullptr; // TODO(macos): wire up a signal handler if crash dumps are wanted.
}

// ---------------------------------------------------------------------------
// MessageBox -> stderr. Flags are accepted and ignored.
// ---------------------------------------------------------------------------
#ifndef MB_OK
#define MB_OK              0x00000000u
#endif
#ifndef MB_ABORTRETRYIGNORE
#define MB_ABORTRETRYIGNORE 0x00000002u
#endif
#ifndef MB_ICONSTOP
#define MB_ICONSTOP        0x00000010u
#endif
#ifndef MB_SETFOREGROUND
#define MB_SETFOREGROUND   0x00010000u
#endif
#ifndef MB_TASKMODAL
#define MB_TASKMODAL       0x00002000u
#endif
#ifndef MB_OKCANCEL
#define MB_OKCANCEL        0x00000001u
#endif
#ifndef MB_ICONINFORMATION
#define MB_ICONINFORMATION 0x00000040u
#endif
#ifndef MB_ICONEXCLAMATION
#define MB_ICONEXCLAMATION 0x00000030u
#endif
#ifndef MB_ICONERROR
#define MB_ICONERROR       0x00000010u
#endif
#ifndef MB_APPLMODAL
#define MB_APPLMODAL       0x00000000u
#endif
#ifndef MB_SYSTEMMODAL
#define MB_SYSTEMMODAL     0x00001000u
#endif
#ifndef IDCANCEL
#define IDCANCEL 2
#endif
#ifndef IDOK
#define IDOK     1
#endif
#ifndef IDABORT
#define IDABORT  3
#endif
#ifndef IDRETRY
#define IDRETRY  4
#endif
#ifndef IDIGNORE
#define IDIGNORE 5
#endif

inline int MessageBox(void * /*hwnd*/, const char *text,
                      const char *caption, unsigned /*type*/)
{
  ::fprintf(stderr, "[MessageBox] %s: %s\n",
            caption ? caption : "", text ? text : "");
  return IDOK;
}

// ---------------------------------------------------------------------------
// wsprintf -> sprintf. (Win32 wsprintf has no float support but the callers
// only use %s/%i/%x, so plain sprintf is a faithful superset here.)
// ---------------------------------------------------------------------------
inline int wsprintf(char *buffer, const char *format, ...)
{
  va_list args;
  va_start(args, format);
  int r = ::vsprintf(buffer, format, args);
  va_end(args);
  return r;
}

// ---------------------------------------------------------------------------
// Console (debug_io_con.cpp). Colored output / key events are non-essential;
// stubs write to stdout and report "no input available".
// ---------------------------------------------------------------------------
#ifndef STD_INPUT_HANDLE
#define STD_INPUT_HANDLE  ((DWORD)-10)
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define STD_ERROR_HANDLE  ((DWORD)-12)
#endif

// Console text attribute bits (passed only to our own stub WriteConsoleOutput).
#ifndef FOREGROUND_BLUE
#define FOREGROUND_BLUE      0x0001
#define FOREGROUND_GREEN     0x0002
#define FOREGROUND_RED       0x0004
#define FOREGROUND_INTENSITY 0x0008
#define BACKGROUND_BLUE      0x0010
#define BACKGROUND_GREEN     0x0020
#define BACKGROUND_RED       0x0040
#define BACKGROUND_INTENSITY 0x0080
#endif

#ifndef KEY_EVENT
#define KEY_EVENT 0x0001
#endif

typedef struct _COORD { SHORT X; SHORT Y; } COORD;
typedef struct _SMALL_RECT { SHORT Left; SHORT Top; SHORT Right; SHORT Bottom; } SMALL_RECT;
typedef struct _CONSOLE_SCREEN_BUFFER_INFO {
  COORD dwSize;
  COORD dwCursorPosition;
  WORD  wAttributes;
  SMALL_RECT srWindow;
  COORD dwMaximumWindowSize;
} CONSOLE_SCREEN_BUFFER_INFO;
typedef struct _CONSOLE_CURSOR_INFO { DWORD dwSize; BOOL bVisible; } CONSOLE_CURSOR_INFO;
typedef struct _CHAR_INFO {
  union { WCHAR UnicodeChar; CHAR AsciiChar; } Char;
  WORD Attributes;
} CHAR_INFO;
typedef struct _KEY_EVENT_RECORD {
  BOOL  bKeyDown;
  WORD  wRepeatCount;
  WORD  wVirtualKeyCode;
  WORD  wVirtualScanCode;
  union { WCHAR UnicodeChar; CHAR AsciiChar; } uChar;
  DWORD dwControlKeyState;
} KEY_EVENT_RECORD;
typedef struct _INPUT_RECORD {
  WORD EventType;
  union { KEY_EVENT_RECORD KeyEvent; } Event;
} INPUT_RECORD;

inline BOOL   AllocConsole()                                  { return FALSE; } // we never own a console on macOS
inline BOOL   FreeConsole()                                   { return TRUE; }
inline HANDLE GetStdHandle(DWORD which)
{
  if (which == STD_INPUT_HANDLE)  return osdep_compat_detail::fd_to_handle(0);
  if (which == STD_OUTPUT_HANDLE) return osdep_compat_detail::fd_to_handle(1);
  return osdep_compat_detail::fd_to_handle(2);
}
inline BOOL SetConsoleMode(HANDLE, DWORD)                                  { return TRUE; }
inline BOOL GetConsoleScreenBufferInfo(HANDLE, CONSOLE_SCREEN_BUFFER_INFO *info)
{
  if (info) ::memset(info, 0, sizeof(*info));
  return TRUE;
}
inline BOOL SetConsoleScreenBufferSize(HANDLE, COORD)                      { return TRUE; }
inline BOOL SetConsoleCursorInfo(HANDLE, const CONSOLE_CURSOR_INFO *)      { return TRUE; }
inline BOOL SetConsoleWindowInfo(HANDLE, BOOL, const SMALL_RECT *)         { return TRUE; }
inline BOOL GetNumberOfConsoleInputEvents(HANDLE, DWORD *count)            { if (count) *count = 0; return TRUE; }
inline BOOL ReadConsoleInput(HANDLE, INPUT_RECORD *, DWORD, DWORD *read)   { if (read) *read = 0; return TRUE; }
inline BOOL WriteConsoleOutput(HANDLE, const CHAR_INFO *, COORD, COORD, SMALL_RECT *) { return TRUE; }

// ---------------------------------------------------------------------------
// wvsprintf (vararg sibling of wsprintf) -> vsprintf.
// ---------------------------------------------------------------------------
inline int wvsprintf(char *buffer, const char *format, va_list args)
{
  return ::vsprintf(buffer, format, args);
}

// ---------------------------------------------------------------------------
// MSVC radix integer->string helpers (_itoa / _ultoa / _i64toa / _ui64toa).
// Win32 supports radix 2..36; the debug stream uses 2/10/16.
// ---------------------------------------------------------------------------
namespace osdep_compat_detail {
  inline char *radix_utoa(unsigned long long value, char *buf, int radix)
  {
    if (radix < 2 || radix > 36) { buf[0] = 0; return buf; }
    char tmp[72];
    int i = 0;
    do {
      int digit = (int)(value % (unsigned)radix);
      tmp[i++] = (char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
      value /= (unsigned)radix;
    } while (value);
    int j = 0;
    while (i > 0) buf[j++] = tmp[--i];
    buf[j] = 0;
    return buf;
  }
  inline char *radix_itoa(long long value, char *buf, int radix)
  {
    if (radix == 10 && value < 0) {
      buf[0] = '-';
      radix_utoa((unsigned long long)(-value), buf + 1, radix);
      return buf;
    }
    return radix_utoa((unsigned long long)value, buf, radix);
  }
}
inline char *_itoa(int value, char *buf, int radix)
{ return osdep_compat_detail::radix_itoa(value, buf, radix); }
inline char *_ltoa(long value, char *buf, int radix)
{ return osdep_compat_detail::radix_itoa(value, buf, radix); }
inline char *_ultoa(unsigned long value, char *buf, int radix)
{ return osdep_compat_detail::radix_utoa(value, buf, radix); }
inline char *_i64toa(long long value, char *buf, int radix)
{ return osdep_compat_detail::radix_itoa(value, buf, radix); }
inline char *_ui64toa(unsigned long long value, char *buf, int radix)
{ return osdep_compat_detail::radix_utoa(value, buf, radix); }

// ---------------------------------------------------------------------------
// IsBadReadPtr / IsBadCodePtr: there is no portable, race-free way to probe an
// address on POSIX. Used only by the crash memory dump to avoid faulting on a
// bad pointer. Assume the pointer is readable (return FALSE = "not bad"); the
// caller is already in a diagnostic path.
// TODO(macos): could use a SIGSEGV-guarded probe if hardening is needed.
// ---------------------------------------------------------------------------
inline BOOL IsBadReadPtr(const void *ptr, size_t /*len*/) { return ptr ? FALSE : TRUE; }
inline BOOL IsBadCodePtr(void *ptr)                       { return ptr ? FALSE : TRUE; }

// ---------------------------------------------------------------------------
// Synchronization objects (events) and threads.
//
// Win32 HANDLEs for events/threads are modelled as heap pointers to a tagged
// struct. A small tag distinguishes them from the fd+1 file handles and the
// pseudo-handles above (which are never passed to the wait/close paths below
// for these object kinds). CreateEvent / SetEvent / ResetEvent and the
// thread-creation shims (_beginthread) all hand back one of these.
// ---------------------------------------------------------------------------
#include <pthread.h>

#ifndef WAIT_TIMEOUT
#define WAIT_TIMEOUT 0x00000102u
#endif
#ifndef WAIT_FAILED
#define WAIT_FAILED  0xFFFFFFFFu
#endif
// WAIT_OBJECT_0 / INFINITE come from thread_compat.h (pulled via compat.h).

namespace osdep_compat_detail {

enum SyncKind { SYNC_EVENT = 0xE7, SYNC_THREAD = 0x74 };

// A waitable kernel object (event or thread). Backed by a pthread cond/mutex.
// For threads, `signaled` is set true when the thread function returns.
struct SyncObject
{
  int             kind;        // SyncKind
  pthread_mutex_t mutex;
  pthread_cond_t  cond;
  bool            manualReset; // events only
  bool            signaled;
  pthread_t       thread;      // threads only
  void          (*proc)(void *); // _beginthread entry
  void           *arg;
};

inline SyncObject *sync_alloc(int kind)
{
  SyncObject *o = new SyncObject();
  o->kind = kind;
  pthread_mutex_init(&o->mutex, nullptr);
  pthread_cond_init(&o->cond, nullptr);
  o->manualReset = false;
  o->signaled = false;
  o->proc = nullptr;
  o->arg = nullptr;
  return o;
}

// Is this HANDLE one of our heap SyncObjects (as opposed to a pseudo/file
// handle)? Pseudo handles are small negative/low integers; real heap pointers
// are large and aligned. We tag-check defensively.
inline bool sync_is_object(HANDLE h)
{
  if (h == nullptr) return false;
  intptr_t v = (intptr_t)h;
  if (v >= -16 && v <= 16) return false;          // pseudo & small fd handles
  SyncObject *o = (SyncObject *)h;
  return o->kind == SYNC_EVENT || o->kind == SYNC_THREAD;
}

// Wait on a SyncObject for up to timeoutMs (INFINITE blocks). Returns
// WAIT_OBJECT_0 if signaled, WAIT_TIMEOUT on timeout.
inline unsigned sync_wait(SyncObject *o, unsigned timeoutMs)
{
  pthread_mutex_lock(&o->mutex);
  unsigned rc = WAIT_OBJECT_0;
  if (timeoutMs == INFINITE) {
    while (!o->signaled)
      pthread_cond_wait(&o->cond, &o->mutex);
  } else {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  += timeoutMs / 1000;
    ts.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    int wr = 0;
    while (!o->signaled && wr == 0)
      wr = pthread_cond_timedwait(&o->cond, &o->mutex, &ts);
    if (!o->signaled) rc = WAIT_TIMEOUT;
  }
  // Auto-reset events consume the signal.
  if (rc == WAIT_OBJECT_0 && o->kind == SYNC_EVENT && !o->manualReset)
    o->signaled = false;
  pthread_mutex_unlock(&o->mutex);
  return rc;
}

} // namespace osdep_compat_detail

inline HANDLE CreateEvent(void * /*sec*/, BOOL manualReset,
                          BOOL initialState, const char * /*name*/)
{
  osdep_compat_detail::SyncObject *o =
      osdep_compat_detail::sync_alloc(osdep_compat_detail::SYNC_EVENT);
  o->manualReset = (manualReset != FALSE);
  o->signaled    = (initialState != FALSE);
  return (HANDLE)o;
}

inline BOOL SetEvent(HANDLE h)
{
  using namespace osdep_compat_detail;
  if (!sync_is_object(h)) return FALSE;
  SyncObject *o = (SyncObject *)h;
  pthread_mutex_lock(&o->mutex);
  o->signaled = true;
  pthread_cond_broadcast(&o->cond);
  pthread_mutex_unlock(&o->mutex);
  return TRUE;
}

inline BOOL ResetEvent(HANDLE h)
{
  using namespace osdep_compat_detail;
  if (!sync_is_object(h)) return FALSE;
  SyncObject *o = (SyncObject *)h;
  pthread_mutex_lock(&o->mutex);
  o->signaled = false;
  pthread_mutex_unlock(&o->mutex);
  return TRUE;
}

// CreateMutex / ReleaseMutex. Modeled as a manual-reset event: "owned" == not
// signaled, "released" == signaled (so a waiter can acquire it). This is a
// faithful-enough single-process approximation; named cross-process mutexes are
// not supported (the name is ignored).
// TODO(macos): real named-mutex semantics if cross-process locking is needed.
inline HANDLE CreateMutex(void * /*sec*/, BOOL initialOwner, const char * /*name*/)
{
  osdep_compat_detail::SyncObject *o =
      osdep_compat_detail::sync_alloc(osdep_compat_detail::SYNC_EVENT);
  o->manualReset = true;
  o->signaled    = (initialOwner == FALSE); // owned -> not available
  return (HANDLE)o;
}
inline HANDLE CreateMutexA(void *sec, BOOL initialOwner, const char *name)
{ return CreateMutex(sec, initialOwner, name); }
inline BOOL ReleaseMutex(HANDLE h) { return SetEvent(h); }

// HANDLE-typed WaitForSingleObject. Distinct from the CRITICAL_SECTION* overload
// in thread_compat.h (HANDLE is void*, CRITICAL_SECTION is a struct), so both
// coexist by ordinary C++ overload resolution.
inline unsigned WaitForSingleObject(HANDLE h, unsigned timeoutMs)
{
  using namespace osdep_compat_detail;
  if (!sync_is_object(h)) return WAIT_OBJECT_0; // pseudo handle: don't block
  return sync_wait((SyncObject *)h, timeoutMs);
}

namespace osdep_compat_detail {

inline void sync_close(SyncObject *o)
{
  if (!o) return;
  if (o->kind == SYNC_THREAD) {
    // Reap the thread so its resources are released (it has usually exited by
    // the time the engine closes the handle).
    pthread_join(o->thread, nullptr);
  }
  pthread_mutex_destroy(&o->mutex);
  pthread_cond_destroy(&o->cond);
  delete o;
}

// Trampoline matching pthread's start_routine signature.
inline void *thread_trampoline(void *arg)
{
  SyncObject *o = (SyncObject *)arg;
  if (o->proc) o->proc(o->arg);
  pthread_mutex_lock(&o->mutex);
  o->signaled = true;                 // make WaitForSingleObject(thread) return
  pthread_cond_broadcast(&o->cond);
  pthread_mutex_unlock(&o->mutex);
  return nullptr;
}

} // namespace osdep_compat_detail

// ---------------------------------------------------------------------------
// _beginthread / _beginthreadex (MSVC CRT). The engine treats the return value
// as a HANDLE. We back it with pthread_create and hand back a SYNC_THREAD
// object so WaitForSingleObject / CloseHandle work on it.
//   uintptr_t _beginthread(void (__cdecl *)(void*), unsigned stack, void *arg);
// ---------------------------------------------------------------------------
inline uintptr_t _beginthread(void (*start)(void *), unsigned /*stackSize*/, void *arg)
{
  using namespace osdep_compat_detail;
  SyncObject *o = sync_alloc(SYNC_THREAD);
  o->proc = start;
  o->arg  = arg;
  if (pthread_create(&o->thread, nullptr, thread_trampoline, o) != 0) {
    sync_close(o);
    return (uintptr_t)-1; // matches Win32 _beginthread failure
  }
  return (uintptr_t)o;
}

inline uintptr_t _beginthreadex(void * /*sec*/, unsigned /*stackSize*/,
                                unsigned (*start)(void *), void *arg,
                                unsigned /*initFlag*/, unsigned *threadId)
{
  using namespace osdep_compat_detail;
  // Adapt the unsigned-returning entry to our void-returning trampoline by
  // stashing it; reuse the same SyncObject machinery.
  SyncObject *o = sync_alloc(SYNC_THREAD);
  // Wrap: store the unsigned-returning proc via a static thunk is overkill;
  // since callers ignore the return code here, cast is acceptable.
  o->proc = reinterpret_cast<void (*)(void *)>(start);
  o->arg  = arg;
  if (pthread_create(&o->thread, nullptr, thread_trampoline, o) != 0) {
    sync_close(o);
    return 0; // _beginthreadex returns 0 on failure
  }
  if (threadId) *threadId = (unsigned)(uintptr_t)o->thread;
  return (uintptr_t)o;
}

// ---------------------------------------------------------------------------
// lstr* string helpers (Win32 USER32/KERNEL32 thin wrappers over CRT str*).
// ---------------------------------------------------------------------------
#include <strings.h>   // strcasecmp
inline int  lstrcmp(const char *a, const char *b)   { return ::strcmp(a ? a : "", b ? b : ""); }
inline int  lstrcmpi(const char *a, const char *b)  { return ::strcasecmp(a ? a : "", b ? b : ""); }
inline int  lstrlen(const char *s)                  { return s ? (int)::strlen(s) : 0; }
inline char *lstrcpy(char *dst, const char *src)    { return ::strcpy(dst, src ? src : ""); }
inline char *lstrcat(char *dst, const char *src)    { return ::strcat(dst, src ? src : ""); }

// ---------------------------------------------------------------------------
// Named pipes (debug_io_net.cpp). Remote-debugger transport: stub to failure.
// ---------------------------------------------------------------------------
#ifndef PIPE_READMODE_MESSAGE
#define PIPE_READMODE_MESSAGE 0x00000002u
#define PIPE_WAIT             0x00000000u
#define PIPE_NOWAIT           0x00000001u
#endif
inline BOOL SetNamedPipeHandleState(HANDLE, DWORD *, void *, void *) { return FALSE; }

// ---------------------------------------------------------------------------
// Dynamic loading: LoadLibrary / GetProcAddress / FreeLibrary -> dlopen family.
//
// Used by WW3D2 (dx8wrapper.cpp) to probe optional DLLs (D3D8.DLL, NvPerfHud,
// etc.). On macOS none of these exist, so loads simply fail gracefully and the
// engine takes its "feature not available" path. We map the requested DLL name
// to a .dylib name as a best effort, but typically dlopen returns null here.
// TODO(macos): real impl needs Metal-backed D3D8 replacement; for now this only
// has to compile and fail-to-load cleanly.
// ---------------------------------------------------------------------------
#include <dlfcn.h>
#include <string>

inline HMODULE LoadLibrary(const char *name)
{
  if (!name) return nullptr;
  // Try the name as-is first, then with a .dylib swap for a trailing .dll/.DLL.
  if (void *h = ::dlopen(name, RTLD_NOW | RTLD_LOCAL)) return (HMODULE)h;
  std::string s(name);
  size_t dot = s.find_last_of('.');
  std::string base = (dot == std::string::npos) ? s : s.substr(0, dot);
  std::string alt = base + ".dylib";
  if (void *h = ::dlopen(alt.c_str(), RTLD_NOW | RTLD_LOCAL)) return (HMODULE)h;
  std::string lib = std::string("lib") + base + ".dylib";
  return (HMODULE)::dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL);
}
inline HMODULE LoadLibraryA(const char *name) { return LoadLibrary(name); }

// FARPROC: a generic callable function pointer (Win32 `INT_PTR (WINAPI*)()`).
// Callers either invoke it directly as a no-arg call -- proc() -- or cast it to
// a concrete signature first; an unprototyped `int(*)()` satisfies both. The
// debug/particle DLLs addressed via GetProcAddress are Windows-only, so on macOS
// GetProcAddress returns null and these calls are never reached.
#ifndef _FARPROC_DEFINED
#define _FARPROC_DEFINED
typedef int (*FARPROC)();
#endif

inline FARPROC GetProcAddress(HMODULE mod, const char *name)
{
  if (!mod || !name) return nullptr;
  return reinterpret_cast<FARPROC>(::dlsym((void *)mod, name));
}

inline BOOL FreeLibrary(HMODULE mod)
{
  if (!mod) return FALSE;
  return ::dlclose((void *)mod) == 0 ? TRUE : FALSE;
}

// GetSystemDirectory: there is no Windows system DLL directory on macOS. Report
// an empty path; callers append a DLL name and the subsequent LoadLibrary fails
// gracefully (e.g. DbgHelpLoader probing for dbghelp.dll).
// TODO(macos): no analogue; symbolication would use native APIs instead.
inline UINT GetSystemDirectory(char *buf, UINT size)
{
  if (buf && size) buf[0] = 0;
  return 0;
}
inline UINT GetSystemDirectoryA(char *buf, UINT size) { return GetSystemDirectory(buf, size); }

inline HMODULE GetModuleHandle(const char * /*name*/)
{
  // Returns a handle to the main executable image. RTLD_DEFAULT works for
  // symbol lookups; callers only use this as an opaque non-null token.
  return (HMODULE)::dlopen(nullptr, RTLD_NOW | RTLD_LOCAL);
}
inline HMODULE GetModuleHandleA(const char *name) { return GetModuleHandle(name); }

// ---------------------------------------------------------------------------
// CRT / string helpers missing on clang.
// ---------------------------------------------------------------------------
#ifndef _WIN32_OSDEP_HAS_STRDUP_ALIAS
#define _WIN32_OSDEP_HAS_STRDUP_ALIAS 1
inline char *_strdup(const char *s) { return ::strdup(s ? s : ""); }
#endif

// In-place uppercase, returns the buffer (MSVC strupr/_strupr semantics).
// NB: _strlwr / strlwr are already provided by Utility/string_compat.h, so we
// only add the uppercase variants here (which it lacks).
// C language linkage so this matches the GameSpy SDK's
// `extern "C" char* _strupr(char*)` prototype (gsplatform.h); otherwise clang
// reports "different language linkage" when both are visible.
extern "C" inline char *_strupr(char *s)
{
  if (s) for (char *p = s; *p; ++p) *p = (char)::toupper((unsigned char)*p);
  return s;
}
#ifndef strupr
#define strupr _strupr
#endif

// lstrcpyn: bounded copy that always null-terminates (Win32 semantics: copies
// up to count-1 chars then a NUL). Returns dst.
inline char *lstrcpyn(char *dst, const char *src, int count)
{
  if (!dst || count <= 0) return dst;
  int i = 0;
  if (src) for (; i < count - 1 && src[i]; ++i) dst[i] = src[i];
  dst[i] = 0;
  return dst;
}

// MulDiv: (a * b) / c with rounding, 64-bit intermediate to avoid overflow.
inline int MulDiv(int a, int b, int c)
{
  if (c == 0) return -1;
  long long r = ((long long)a * (long long)b);
  // round to nearest
  if ((r < 0) != (c < 0)) r -= c / 2; else r += c / 2;
  return (int)(r / c);
}

#ifndef _isnan
#define _isnan(x) (std::isnan(x))
#endif
#ifndef _finite
#define _finite(x) (std::isfinite(x))
#endif

// ---------------------------------------------------------------------------
// File-system query helpers used by WW3D2 asset loading (agg_def.cpp).
// ---------------------------------------------------------------------------
#ifndef INVALID_FILE_ATTRIBUTES
#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)
#endif
#ifndef FILE_ATTRIBUTE_DIRECTORY
#define FILE_ATTRIBUTE_DIRECTORY 0x00000010u
#endif
inline DWORD GetCurrentDirectory(DWORD size, char *buf)
{
  if (!buf || !size) return 0;
  if (::getcwd(buf, size) == nullptr) { buf[0] = 0; return 0; }
  return (DWORD)::strlen(buf);
}
inline DWORD GetFileAttributes(const char *path)
{
  if (!path) return INVALID_FILE_ATTRIBUTES;
  struct stat st;
  if (::stat(osdep_compat_detail::np(path), &st) != 0) return INVALID_FILE_ATTRIBUTES;
  return (st.st_mode & S_IFDIR) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
}

// ---------------------------------------------------------------------------
// Window / monitor / GDI stubs.
//
// There is no real HWND, monitor or GDI surface on macOS yet. Window ops are
// no-ops that report sane defaults; a real SDL window + Metal back end arrives
// in a later phase. Every routine here is a runtime-rendering gap.
// TODO(macos): real impl needs SDL window / Metal.
// ---------------------------------------------------------------------------

// SetWindowPos flags / special HWND values.
#ifndef SWP_NOSIZE
#define SWP_NOSIZE        0x0001
#define SWP_NOMOVE        0x0002
#define SWP_NOZORDER      0x0004
#define SWP_NOACTIVATE    0x0010
#define SWP_SHOWWINDOW    0x0040
#define SWP_FRAMECHANGED  0x0020
#endif
#ifndef HWND_TOP
#define HWND_TOP        ((HWND)0)
#define HWND_BOTTOM     ((HWND)1)
#define HWND_TOPMOST    ((HWND)-1)
#define HWND_NOTOPMOST  ((HWND)-2)
#endif

// GetWindowLong / SetWindowLong indices and window-style bits.
#ifndef GWL_STYLE
#define GWL_WNDPROC    (-4)
#define GWL_HINSTANCE  (-6)
#define GWL_ID         (-12)
#define GWL_STYLE      (-16)
#define GWL_EXSTYLE    (-20)
#define GWL_USERDATA   (-21)
#endif
#ifndef WS_OVERLAPPED
#define WS_OVERLAPPED    0x00000000u
#define WS_POPUP         0x80000000u
#define WS_CHILD         0x40000000u
#define WS_VISIBLE       0x10000000u
#define WS_CAPTION       0x00C00000u
#define WS_SYSMENU       0x00080000u
#define WS_THICKFRAME    0x00040000u
#define WS_MINIMIZEBOX   0x00020000u
#define WS_MAXIMIZEBOX   0x00010000u
#define WS_BORDER        0x00800000u
#define WS_DLGFRAME      0x00400000u
#define WS_OVERLAPPEDWINDOW (WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_THICKFRAME|WS_MINIMIZEBOX|WS_MAXIMIZEBOX)
#define WS_EX_TOPMOST    0x00000008u
#endif

inline BOOL GetClientRect(HWND /*hwnd*/, RECT *r)
{
  if (r) { r->left = r->top = 0; r->right = 0; r->bottom = 0; }
  return TRUE; // TODO(macos): real impl needs SDL window / Metal.
}
inline BOOL GetWindowRect(HWND /*hwnd*/, RECT *r)
{
  if (r) { r->left = r->top = 0; r->right = 0; r->bottom = 0; }
  return TRUE; // TODO(macos): real impl needs SDL window / Metal.
}
inline BOOL SetWindowPos(HWND, HWND, int, int, int, int, unsigned)
{ return TRUE; }     // TODO(macos): real impl needs SDL window / Metal.
inline LONG GetWindowLong(HWND, int)            { return 0; }   // TODO(macos)
inline LONG SetWindowLong(HWND, int, LONG)      { return 0; }   // TODO(macos)
inline BOOL ClientToScreen(HWND, POINT *)       { return TRUE; }
inline BOOL ScreenToClient(HWND, POINT *)       { return TRUE; }
inline BOOL AdjustWindowRect(RECT *, DWORD, BOOL) { return TRUE; }
inline BOOL ShowWindow(HWND, int)               { return TRUE; }
inline BOOL UpdateWindow(HWND)                  { return TRUE; }
// Window title: no OS window yet. TODO(macos): SDL_SetWindowTitle.
inline BOOL SetWindowText(HWND, const char *)   { return TRUE; }
inline BOOL SetWindowTextA(HWND h, const char *s)  { return SetWindowText(h, s); }
inline BOOL SetWindowTextW(HWND, const WCHAR *) { return TRUE; }
inline HWND GetDesktopWindow()                  { return nullptr; }
inline HWND GetForegroundWindow()               { return nullptr; }
inline BOOL IsWindow(HWND h)                    { return h != nullptr; }

// GetSystemMetrics: report a plausible default desktop. Used to clamp window
// sizes; 0 is acceptable for "unknown".
#ifndef SM_CXSCREEN
#define SM_CXSCREEN 0
#define SM_CYSCREEN 1
#endif
inline int GetSystemMetrics(int index)
{
  if (index == SM_CXSCREEN) return 1920;
  if (index == SM_CYSCREEN) return 1080;
  return 0; // TODO(macos): real impl needs SDL/AppKit display query.
}

// ---------------------------------------------------------------------------
// Monitor enumeration (dx8wrapper full-screen handling).
// ---------------------------------------------------------------------------
#ifndef MONITOR_DEFAULTTONULL
#define MONITOR_DEFAULTTONULL    0x00000000u
#define MONITOR_DEFAULTTOPRIMARY 0x00000001u
#define MONITOR_DEFAULTTONEAREST 0x00000002u
#endif
#ifndef CCHDEVICENAME
#define CCHDEVICENAME 32
#endif
typedef struct tagMONITORINFO {
  DWORD cbSize;
  RECT  rcMonitor;
  RECT  rcWork;
  DWORD dwFlags;
} MONITORINFO, *LPMONITORINFO;
typedef struct tagMONITORINFOEXA {
  DWORD cbSize;
  RECT  rcMonitor;
  RECT  rcWork;
  DWORD dwFlags;
  CHAR  szDevice[CCHDEVICENAME];
} MONITORINFOEXA, *LPMONITORINFOEXA;
typedef MONITORINFOEXA MONITORINFOEX;
typedef LPMONITORINFOEXA LPMONITORINFOEX;

inline HMONITOR MonitorFromWindow(HWND, DWORD)
{
  return (HMONITOR)(intptr_t)1; // single fake primary monitor token
}
inline HMONITOR MonitorFromPoint(POINT, DWORD)
{
  return (HMONITOR)(intptr_t)1;
}
inline BOOL GetMonitorInfo(HMONITOR, LPMONITORINFO mi)
{
  // Report a 1920x1080 primary monitor at the origin.
  // TODO(macos): real impl needs AppKit/CoreGraphics display query.
  if (!mi) return FALSE;
  mi->rcMonitor.left = 0; mi->rcMonitor.top = 0;
  mi->rcMonitor.right = 1920; mi->rcMonitor.bottom = 1080;
  mi->rcWork = mi->rcMonitor;
  mi->dwFlags = MONITOR_DEFAULTTOPRIMARY;
  return TRUE;
}
inline BOOL GetMonitorInfoA(HMONITOR h, LPMONITORINFO mi) { return GetMonitorInfo(h, mi); }

// ---------------------------------------------------------------------------
// GDI / font constants referenced by render2dsentence.cpp / font3d.cpp.
// (Real GDI text rendering is replaced later; these only need to compile.)
// ---------------------------------------------------------------------------
#ifndef FW_NORMAL
#define FW_DONTCARE   0
#define FW_THIN       100
#define FW_NORMAL     400
#define FW_REGULAR    400
#define FW_MEDIUM     500
#define FW_SEMIBOLD   600
#define FW_BOLD       700
#endif
#ifndef ANSI_CHARSET
#define ANSI_CHARSET        0
#define DEFAULT_CHARSET     1
#define SYMBOL_CHARSET      2
#endif
#ifndef OUT_DEFAULT_PRECIS
#define OUT_DEFAULT_PRECIS   0
#define OUT_TT_PRECIS        4
#define OUT_TT_ONLY_PRECIS   7
#endif
#ifndef CLIP_DEFAULT_PRECIS
#define CLIP_DEFAULT_PRECIS  0
#endif
#ifndef DEFAULT_QUALITY
#define DEFAULT_QUALITY        0
#define DRAFT_QUALITY          1
#define PROOF_QUALITY          2
#define NONANTIALIASED_QUALITY 3
#define ANTIALIASED_QUALITY    4
#endif
#ifndef DEFAULT_PITCH
#define DEFAULT_PITCH   0
#define FIXED_PITCH     1
#define VARIABLE_PITCH  2
#endif
#ifndef FF_DONTCARE
#define FF_DONTCARE   0x00
#define FF_ROMAN      0x10
#define FF_SWISS      0x20
#define FF_MODERN     0x30
#endif
#ifndef ETO_OPAQUE
#define ETO_OPAQUE    0x0002
#define ETO_CLIPPED   0x0004
#endif
#ifndef DIB_RGB_COLORS
#define DIB_RGB_COLORS  0
#define DIB_PAL_COLORS  1
#endif
#ifndef BI_RGB
#define BI_RGB  0
#endif
#ifndef TRANSPARENT
#define TRANSPARENT 1
#define OPAQUE      2
#endif
#ifndef SRCCOPY
#define SRCCOPY  0x00CC0020u
#endif

// BITMAPINFO family (used by font glyph rasterization via CreateDIBSection).
typedef struct tagBITMAPINFOHEADER {
  DWORD biSize; LONG biWidth; LONG biHeight; WORD biPlanes; WORD biBitCount;
  DWORD biCompression; DWORD biSizeImage; LONG biXPelsPerMeter;
  LONG biYPelsPerMeter; DWORD biClrUsed; DWORD biClrImportant;
} BITMAPINFOHEADER, *PBITMAPINFOHEADER, *LPBITMAPINFOHEADER;
typedef struct tagBITMAPINFO {
  BITMAPINFOHEADER bmiHeader;
  RGBQUAD bmiColors[1];
} BITMAPINFO, *PBITMAPINFO, *LPBITMAPINFO;
// BITMAPFILEHEADER is the 14-byte on-disk .bmp prefix; it must be packed so
// sizeof()/field offsets match the file format (ww3d.cpp screenshot writer).
#pragma pack(push, 2)
typedef struct tagBITMAPFILEHEADER {
  WORD  bfType; DWORD bfSize; WORD bfReserved1; WORD bfReserved2; DWORD bfOffBits;
} BITMAPFILEHEADER, *PBITMAPFILEHEADER, *LPBITMAPFILEHEADER;
#pragma pack(pop)
typedef struct tagTEXTMETRICA {
  LONG tmHeight; LONG tmAscent; LONG tmDescent; LONG tmInternalLeading;
  LONG tmExternalLeading; LONG tmAveCharWidth; LONG tmMaxCharWidth;
  LONG tmWeight; LONG tmOverhang; LONG tmDigitizedAspectX;
  LONG tmDigitizedAspectY; CHAR tmFirstChar; CHAR tmLastChar;
  CHAR tmDefaultChar; CHAR tmBreakChar; BYTE tmItalic; BYTE tmUnderlined;
  BYTE tmStruckOut; BYTE tmPitchAndFamily; BYTE tmCharSet;
} TEXTMETRICA, *PTEXTMETRICA, *LPTEXTMETRICA;
typedef TEXTMETRICA TEXTMETRIC;
typedef LPTEXTMETRICA LPTEXTMETRIC;
typedef struct tagABC { int abcA; UINT abcB; int abcC; } ABC, *LPABC;

// GDI device-context / object stubs.
//
// On macOS the font-rasterization subset (GetDC/CreateFont/CreateDIBSection/
// SelectObject/ExtTextOutW/GetTextMetrics/GetTextExtentPoint32W/colors/delete)
// is implemented for real via Core Text + Core Graphics in
// cmake/dx8_stub/gdi_text.mm (linked through the `d3d8` target). So those are
// declared `extern` here, not defined inline. The remaining GDI calls (BitBlt,
// pixels, gamma, ANSI text, char-widths) have no consumers in the macOS build
// and stay as harmless inline stubs.
#if defined(__APPLE__)
extern HDC     GetDC(HWND);
extern int     ReleaseDC(HWND, HDC);
extern HDC     CreateCompatibleDC(HDC);
extern BOOL    DeleteDC(HDC);
extern HBITMAP CreateDIBSection(HDC, const BITMAPINFO *, UINT, void **bits, HANDLE, DWORD);
extern HGDIOBJ SelectObject(HDC, HGDIOBJ);
extern BOOL    DeleteObject(HGDIOBJ);
extern HFONT   CreateFont(int, int, int, int, int, DWORD, DWORD, DWORD,
                          DWORD, DWORD, DWORD, DWORD, DWORD, const char *);
extern HFONT   CreateFontIndirect(const LOGFONT *);
extern int     GetTextMetrics(HDC, TEXTMETRIC *tm);
extern COLORREF SetTextColor(HDC, COLORREF);
extern COLORREF SetBkColor(HDC, COLORREF);
extern BOOL    ExtTextOutW(HDC, int, int, UINT, const RECT *, const WCHAR *, UINT, const int *);
extern DWORD   GetTextExtentPoint32W(HDC, const WCHAR *, int, SIZE *sz);
#else
inline HDC     GetDC(HWND)                                   { return nullptr; }
inline int     ReleaseDC(HWND, HDC)                          { return 1; }
inline HDC     CreateCompatibleDC(HDC)                       { return nullptr; }
inline BOOL    DeleteDC(HDC)                                 { return TRUE; }
inline HBITMAP CreateDIBSection(HDC, const BITMAPINFO *, UINT, void **bits, HANDLE, DWORD)
{ if (bits) *bits = nullptr; return nullptr; }
inline HGDIOBJ SelectObject(HDC, HGDIOBJ)                    { return nullptr; }
inline BOOL    DeleteObject(HGDIOBJ)                         { return TRUE; }
inline HFONT   CreateFont(int, int, int, int, int, DWORD, DWORD, DWORD,
                          DWORD, DWORD, DWORD, DWORD, DWORD, const char *)
{ return nullptr; }
inline HFONT   CreateFontIndirect(const LOGFONT *)           { return nullptr; }
inline int     GetTextMetrics(HDC, TEXTMETRIC *tm)           { if (tm) ::memset(tm, 0, sizeof(*tm)); return TRUE; }
inline COLORREF SetTextColor(HDC, COLORREF)                  { return 0; }
inline COLORREF SetBkColor(HDC, COLORREF)                    { return 0; }
inline BOOL    ExtTextOutW(HDC, int, int, UINT, const RECT *, const WCHAR *, UINT, const int *) { return TRUE; }
inline DWORD   GetTextExtentPoint32W(HDC, const WCHAR *, int, SIZE *sz) { if (sz) { sz->cx = 0; sz->cy = 0; } return TRUE; }
#endif
inline HBITMAP CreateCompatibleBitmap(HDC, int, int)         { return nullptr; }
inline DWORD   GetTextExtentPoint32(HDC, const char *, int, SIZE *sz) { if (sz) { sz->cx = 0; sz->cy = 0; } return TRUE; }
inline BOOL    GetCharABCWidths(HDC, UINT, UINT, LPABC abc)  { if (abc) ::memset(abc, 0, sizeof(*abc)); return TRUE; }
inline BOOL    GetCharWidth32(HDC, UINT, UINT, int *w)       { if (w) *w = 0; return TRUE; }
inline int     SetBkMode(HDC, int)                           { return 0; }
inline BOOL    ExtTextOut(HDC, int, int, UINT, const RECT *, const char *, UINT, const int *) { return TRUE; }
inline BOOL    TextOut(HDC, int, int, const char *, int)     { return TRUE; }
inline int     SetMapMode(HDC, int)                          { return 0; }
inline COLORREF GetPixel(HDC, int, int)                      { return 0; }
// SetDeviceGammaRamp / GetDeviceGammaRamp: no GDI gamma control on macOS. The
// second arg is a 3x256 WORD ramp (D3DGAMMARAMP-compatible) -> accept as void*.
// TODO(macos): real impl needs CGSetDisplayTransferByTable or Metal.
inline BOOL    SetDeviceGammaRamp(HDC, void *)               { return FALSE; }
inline BOOL    GetDeviceGammaRamp(HDC, void *)               { return FALSE; }
inline COLORREF SetPixel(HDC, int, int, COLORREF)            { return 0; }
inline BOOL    BitBlt(HDC, int, int, int, int, HDC, int, int, DWORD) { return TRUE; }
inline int     GetDeviceCaps(HDC, int)                       { return 0; }

// ---------------------------------------------------------------------------
// Process heap -> malloc/free. Win32 distinguishes the process heap handle, but
// on POSIX we only need a non-null token and the alloc/free behaviour.
// ---------------------------------------------------------------------------
#ifndef HEAP_ZERO_MEMORY
#define HEAP_ZERO_MEMORY  0x00000008u
#define HEAP_NO_SERIALIZE 0x00000001u
#endif
inline HANDLE GetProcessHeap()                               { return (HANDLE)(intptr_t)1; }
inline void * HeapAlloc(HANDLE /*heap*/, DWORD flags, size_t bytes)
{
  void *p = ::malloc(bytes ? bytes : 1);
  if (p && (flags & HEAP_ZERO_MEMORY)) ::memset(p, 0, bytes);
  return p;
}
inline void * HeapReAlloc(HANDLE /*heap*/, DWORD /*flags*/, void *mem, size_t bytes)
{ return ::realloc(mem, bytes ? bytes : 1); }
inline BOOL   HeapFree(HANDLE /*heap*/, DWORD /*flags*/, void *mem) { ::free(mem); return TRUE; }
inline size_t HeapSize(HANDLE /*heap*/, DWORD /*flags*/, const void *mem)
{
#if defined(__APPLE__)
  return mem ? ::malloc_size(mem) : 0;
#else
  return 0;
#endif
}

// LocalAlloc/LocalFree -> malloc/free. LPTR == zero-initialised fixed memory.
#ifndef LPTR
#define LMEM_FIXED    0x0000
#define LMEM_ZEROINIT 0x0040
#define LPTR          (LMEM_FIXED | LMEM_ZEROINIT)
#endif
inline HLOCAL LocalAlloc(unsigned flags, size_t bytes)
{
  void *p = ::malloc(bytes ? bytes : 1);
  if (p && (flags & LMEM_ZEROINIT)) ::memset(p, 0, bytes);
  return (HLOCAL)p;
}
inline HLOCAL LocalFree(HLOCAL mem) { ::free((void *)mem); return nullptr; }

// ---------------------------------------------------------------------------
// Directory enumeration: FindFirstFile/FindNextFile/FindClose backed by
// opendir/readdir + fnmatch. The Win32 search spec is "<dir>/<glob>"; we split
// off the directory and match the remaining glob pattern against each entry.
// ---------------------------------------------------------------------------
typedef struct _WIN32_FIND_DATAA {
  DWORD    dwFileAttributes;
  FILETIME ftCreationTime;
  FILETIME ftLastAccessTime;
  FILETIME ftLastWriteTime;
  DWORD    nFileSizeHigh;
  DWORD    nFileSizeLow;
  DWORD    dwReserved0;
  DWORD    dwReserved1;
  char     cFileName[MAX_PATH];
  char     cAlternateFileName[14];
} WIN32_FIND_DATAA, *PWIN32_FIND_DATAA, *LPWIN32_FIND_DATAA;
typedef WIN32_FIND_DATAA WIN32_FIND_DATA;
typedef LPWIN32_FIND_DATAA LPWIN32_FIND_DATA;

// Internal find-handle bundle (kept opaque to callers via HANDLE).
struct _Win32FindState {
  DIR *dir;
  std::string directory;   // directory portion incl. trailing separator (or empty)
  std::string pattern;     // glob to match basenames against
};

inline void _Win32FillFindData(const std::string &dirPart,
                               const char *name, WIN32_FIND_DATA *fd)
{
  ::memset(fd, 0, sizeof(*fd));
  ::strncpy(fd->cFileName, name, MAX_PATH - 1);
  std::string full = dirPart.empty() ? std::string(name) : (dirPart + name);
  struct stat st;
  if (::stat(full.c_str(), &st) == 0) {
    fd->dwFileAttributes = (st.st_mode & S_IFDIR) ? FILE_ATTRIBUTE_DIRECTORY
                                                  : FILE_ATTRIBUTE_NORMAL;
    fd->nFileSizeLow  = (DWORD)(st.st_size & 0xffffffffu);
    fd->nFileSizeHigh = (DWORD)((unsigned long long)st.st_size >> 32);
    // Convert POSIX time_t (seconds since 1970) to Win32 FILETIME (100ns ticks
    // since 1601). 11644473600 = seconds between the two epochs.
    unsigned long long ft =
        ((unsigned long long)st.st_mtime + 11644473600ULL) * 10000000ULL;
    fd->ftLastWriteTime.dwLowDateTime  = (DWORD)(ft & 0xffffffffu);
    fd->ftLastWriteTime.dwHighDateTime = (DWORD)(ft >> 32);
  } else {
    fd->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
  }
}

inline HANDLE FindFirstFile(const char *searchSpec, WIN32_FIND_DATA *fd)
{
  if (!searchSpec || !fd) return INVALID_HANDLE_VALUE;
  std::string spec(searchSpec);
  // Normalise Windows separators so the split works on either style.
  for (char &c : spec) { if (c == '\\') c = '/'; }
  std::string dirPart, pattern;
  size_t slash = spec.find_last_of('/');
  if (slash == std::string::npos) { dirPart = ""; pattern = spec; }
  else { dirPart = spec.substr(0, slash + 1); pattern = spec.substr(slash + 1); }
  if (pattern.empty()) pattern = "*";

  // Win32 FindFirstFile wildcard idioms that POSIX fnmatch does NOT share:
  //   "*."  -> every name with no extension. The engine's directory walker
  //            (Win32LocalFileSystem::getFileListInDirectory) uses "*." to
  //            enumerate sub-directories, then keeps the ones flagged as
  //            directories. fnmatch("*.", "SubDir") returns 1 (no literal
  //            trailing dot), so the un-translated pattern matched NOTHING and
  //            every per-map sub-folder — i.e. all on-disk user maps — silently
  //            failed to enumerate.
  //   "*.*" -> Win treats this as "match everything" (including names with no
  //            dot), whereas fnmatch would require a literal '.'.
  // Both collapse to "*"; callers apply their own attribute/extension filter.
  if (pattern == "*." || pattern == "*.*") pattern = "*";

  const char *openPath = dirPart.empty() ? "." : dirPart.c_str();
  DIR *d = ::opendir(openPath);
  if (!d) return INVALID_HANDLE_VALUE;

  _Win32FindState *state = new _Win32FindState{ d, dirPart, pattern };
  struct dirent *ent;
  while ((ent = ::readdir(d)) != nullptr) {
    // FNM_CASEFOLD: Win32 file matching is case-insensitive; emulate it so
    // e.g. "*.map" also matches "Foo.MAP".
    if (::fnmatch(state->pattern.c_str(), ent->d_name, FNM_CASEFOLD) == 0) {
      _Win32FillFindData(state->directory, ent->d_name, fd);
      return (HANDLE)state;
    }
  }
  ::closedir(d);
  delete state;
  return INVALID_HANDLE_VALUE;
}

inline BOOL FindNextFile(HANDLE h, WIN32_FIND_DATA *fd)
{
  if (h == INVALID_HANDLE_VALUE || !h || !fd) return FALSE;
  _Win32FindState *state = (_Win32FindState *)h;
  struct dirent *ent;
  while ((ent = ::readdir(state->dir)) != nullptr) {
    // FNM_CASEFOLD: Win32 file matching is case-insensitive; emulate it so
    // e.g. "*.map" also matches "Foo.MAP".
    if (::fnmatch(state->pattern.c_str(), ent->d_name, FNM_CASEFOLD) == 0) {
      _Win32FillFindData(state->directory, ent->d_name, fd);
      return TRUE;
    }
  }
  return FALSE;
}

inline BOOL FindClose(HANDLE h)
{
  if (h == INVALID_HANDLE_VALUE || !h) return FALSE;
  _Win32FindState *state = (_Win32FindState *)h;
  if (state->dir) ::closedir(state->dir);
  delete state;
  return TRUE;
}

// GetFullPathNameA -> realpath. realpath requires the path to exist; if it does
// not we fall back to cwd-prefixing so the call still returns a usable path.
inline DWORD GetFullPathNameA(const char *name, DWORD bufLen, char *buf, char **filePart)
{
  if (!name) return 0;
  name = osdep_compat_detail::np(name);  // `\`-separated -> POSIX before realpath
  char resolved[PATH_MAX];
  if (::realpath(name, resolved) == nullptr) {
    if (name[0] == '/') { ::strncpy(resolved, name, PATH_MAX - 1); resolved[PATH_MAX-1]=0; }
    else {
      char cwd[PATH_MAX];
      if (::getcwd(cwd, sizeof(cwd)) == nullptr) return 0;
      ::snprintf(resolved, PATH_MAX, "%s/%s", cwd, name);
    }
  }
  DWORD len = (DWORD)::strlen(resolved);
  // TheSuperHackers @port macOS — support the Win32 size-probe idiom: when
  // buf==NULL (or bufLen is too small) return the REQUIRED size *including* the
  // null terminator so the caller can allocate and call again. The old
  // `!buf -> return 0` guard broke Win32LocalFileSystem::normalizePath (which
  // calls GetFullPathNameA(path,0,NULL,NULL) first to size the buffer), which in
  // turn broke Save/Load map-path validation (FileSystem::isPathInDirectory).
  if (!buf || len + 1 > bufLen) return len + 1;
  ::strcpy(buf, resolved);
  if (filePart) {
    char *slash = ::strrchr(buf, '/');
    *filePart = slash ? slash + 1 : buf;
  }
  return len;
}
inline DWORD GetFullPathName(const char *name, DWORD bufLen, char *buf, char **filePart)
{ return GetFullPathNameA(name, bufLen, buf, filePart); }

inline DWORD GetFileAttributesA(const char *path) { return GetFileAttributes(path); }

// CreateDirectory(A) -> mkdir. Second arg is SECURITY_ATTRIBUTES* (ignored).
inline BOOL CreateDirectoryA(const char *path, void * /*sa*/)
{ return (path && ::mkdir(osdep_compat_detail::np(path), 0777) == 0) ? TRUE : FALSE; }
inline BOOL CreateDirectory(const char *path, void *sa) { return CreateDirectoryA(path, sa); }

// MessageBoxW (wide) -> print the (narrowed) text to stderr so engine error
// dialogs are visible on the console during the macOS port bring-up.
inline int MessageBoxW(void * /*hwnd*/, const WCHAR *text,
                       const WCHAR *caption, unsigned /*type*/)
{
  ::fprintf(stderr, "[MessageBox] ");
  if (caption) { for (const WCHAR *c = caption; *c; ++c) ::fputc((char)*c, stderr); ::fprintf(stderr, ": "); }
  if (text)    { for (const WCHAR *c = text; *c; ++c) ::fputc((char)*c, stderr); }
  ::fprintf(stderr, "\n");
  return IDOK;
}

// ---------------------------------------------------------------------------
// Mouse cursor — wire Win32 calls to NSCursor via the Cocoa metal_backend.
// MetalCursor_Show is counter-based (Win32 ShowCursor semantics).
//
// LoadCursorFromFile parses the engine's original .ANI cursor files (RIFF
// container of .CUR frames) into an array of NSCursors via apple_ani_cursor.mm.
// The returned HCURSOR is an opaque pointer to that cached struct; the engine
// stores it per cursor type and passes it back to SetCursor each frame.
//
// SetCursor switches the active animated cursor and hides/shows the system
// cursor as needed. A non-null HCURSOR is the engine's "show some cursor"
// signal; null is "hide cursor (engine draws its own)".
// ---------------------------------------------------------------------------
extern "C" int   MetalCursor_Show(int show);
extern "C" int   MetalCursor_WarpClient(int clientX, int clientY);
extern "C" void* MetalCursor_LoadAni(const char* path);
extern "C" void  MetalCursor_SetActiveAni(void* handle);

// Forward declaration so the inline LoadCursorFromFile below can call
// the path normaliser. The full definition lives in apple_path_shim.h,
// which is pulled in further down windows.h — declaration here keeps
// inline-body parsing happy regardless of include order at the call site.
namespace apple_path { const char* normalize(const char* path); }

inline HCURSOR SetCursor(HCURSOR c) {
    // The engine alternates SetCursor(nullptr) <-> SetCursor(bitmap) each time
    // the cursor mode flips between "software-only" and "system+software".
    // Mirror this on the show/hide counter so the system cursor is hidden
    // whenever the engine is in software-cursor mode.
    static int s_lastHidden = 0;
    int wantHidden = (c == nullptr) ? 1 : 0;
    if (wantHidden != s_lastHidden) {
        MetalCursor_Show(wantHidden ? 0 : 1);   // 0=hide step, 1=show step
        s_lastHidden = wantHidden;
    }
    // Activate the engine-supplied animated cursor (no-op if same as last
    // and the cursor pointer is non-null — see MetalCursor_SetActiveAni).
    // Skip activation for the dummy 0x1 sentinel we hand back when a file
    // failed to parse so we don't dereference a bogus pointer.
    if (c == nullptr || (uintptr_t)c == 0x1) {
        MetalCursor_SetActiveAni(nullptr);
    } else {
        MetalCursor_SetActiveAni((void*)c);
    }
    return nullptr;
}
inline int     ShowCursor(BOOL show)             { return MetalCursor_Show(show ? 1 : 0); }
inline HCURSOR LoadCursorFromFile(const char *path) {
    // Normalise the Windows-style "data\\cursors\\Foo.ANI" the engine
    // hands us into a POSIX path that fopen on macOS can actually open.
    // apple_path::normalize lives in apple_path_shim.h, which is
    // included at the bottom of windows.h on Apple builds.
    const char* posixPath = ::apple_path::normalize(path);
    void* h = MetalCursor_LoadAni(posixPath);
    // Return a dummy non-null if parse failed so the engine's
    // DEBUG_ASSERTCRASH(cursorResources[..]) doesn't trip; SetCursor
    // recognises 0x1 and treats it as "no cursor".
    return h ? (HCURSOR)h : (HCURSOR)0x1;
}
inline HCURSOR LoadCursorFromFileA(const char *p)        { return LoadCursorFromFile(p); }
inline BOOL    GetCursorPos(POINT *p)  { if (p) { p->x = 0; p->y = 0; } return TRUE; }
inline BOOL    SetCursorPos(int x, int y) { return MetalCursor_WarpClient(x, y) ? TRUE : FALSE; }
inline BOOL    ClipCursor(const RECT * /*r*/)            { return TRUE; }
inline BOOL    IsIconic(HWND /*hwnd*/)                   { return FALSE; }
// Keyboard state: no OS keyboard polling yet. Reports "not pressed".
// TODO(macos): real impl reads SDL keyboard state.
inline SHORT   GetAsyncKeyState(int /*vk*/)              { return 0; }
inline SHORT   GetKeyState(int /*vk*/)                   { return 0; }

// ---------------------------------------------------------------------------
// CreateThread -> pthread. Maps the Win32 LPTHREAD_START_ROUTINE (DWORD(void*))
// onto a pthread start function; the returned HANDLE wraps the pthread_t.
// (Most engine threading already routed elsewhere; this covers stragglers.)
// ---------------------------------------------------------------------------
typedef DWORD (*LPTHREAD_START_ROUTINE)(void *);
inline HANDLE CreateThread(void * /*sa*/, size_t /*stack*/,
                           LPTHREAD_START_ROUTINE start, void *param,
                           DWORD /*flags*/, DWORD *threadId)
{
  if (threadId) *threadId = 0;
  pthread_t tid;
  // pthread start routine returns void*; the Win32 routine returns DWORD. Wrap.
  struct _Trampoline {
    LPTHREAD_START_ROUTINE fn; void *arg;
    static void *run(void *self) {
      _Trampoline *t = (_Trampoline *)self;
      if (t->fn) t->fn(t->arg);
      delete t;
      return nullptr;
    }
  };
  _Trampoline *t = new _Trampoline{ start, param };
  if (::pthread_create(&tid, nullptr, &_Trampoline::run, t) != 0) { delete t; return nullptr; }
  return (HANDLE)(intptr_t)tid;
}

// ---------------------------------------------------------------------------
// SetThreadExecutionState: prevents display/system sleep on Windows. No-op on
// macOS for now (real impl would use IOPMAssertion). TODO(macos).
// ---------------------------------------------------------------------------
typedef DWORD EXECUTION_STATE;
#ifndef ES_CONTINUOUS
#define ES_CONTINUOUS       ((EXECUTION_STATE)0x80000000u)
#define ES_SYSTEM_REQUIRED  ((EXECUTION_STATE)0x00000001u)
#define ES_DISPLAY_REQUIRED ((EXECUTION_STATE)0x00000002u)
#endif
inline EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE /*flags*/) { return ES_CONTINUOUS; }

// ===========================================================================
// Final compile-wave shims (Common / SaveGame / GameLogic / GameClient).
// All compile-only; behavioural fidelity is not required for these paths yet.
// ===========================================================================

// --- itoa (non-underscore MSVC spelling) -> reuse _itoa above. -------------
inline char *itoa(int value, char *buf, int radix)
{ return osdep_compat_detail::radix_itoa(value, buf, radix); }

// --- _wtoi: wide-string to int. --------------------------------------------
inline int _wtoi(const WCHAR *s)
{
  if (!s) return 0;
  long v = 0; int sign = 1; const WCHAR *p = s;
  while (*p == L' ' || *p == L'\t') ++p;
  if (*p == L'-') { sign = -1; ++p; } else if (*p == L'+') ++p;
  while (*p >= L'0' && *p <= L'9') { v = v * 10 + (*p - L'0'); ++p; }
  return (int)(v * sign);
}

// --- FPU control word (_controlfp / _statusfp / _fpreset). -----------------
// No portable FPU-control on arm64 macOS; these are no-ops returning a benign
// "default rounding / 53-bit precision" word. The engine uses them only to set
// deterministic FP behaviour for replays; on arm64 the default is already
// round-to-nearest with no x87 extended precision.
// TODO(macos): if cross-platform replay determinism is needed, set FPCR here.
#ifndef _MCW_PC
#define _MCW_PC   0x00030000u   // precision-control mask
#define _PC_24    0x00020000u
#define _PC_53    0x00010000u
#define _PC_64    0x00000000u
#endif
#ifndef _MCW_RC
#define _MCW_RC   0x00000300u   // rounding-control mask
#define _RC_NEAR  0x00000000u
#define _RC_DOWN  0x00000100u
#define _RC_UP    0x00000200u
#define _RC_CHOP  0x00000300u
#endif
#ifndef _MCW_EM
#define _MCW_EM   0x0008001fu   // exception-mask
#endif
inline unsigned int _controlfp(unsigned int /*newv*/, unsigned int /*mask*/) { return _PC_53 | _RC_NEAR; }
inline unsigned int _statusfp() { return 0; }
inline void _fpreset() { }
inline void _clearfp() { }

// --- OS version info (GetVersionEx). ---------------------------------------
#ifndef VER_PLATFORM_WIN32_WINDOWS
#define VER_PLATFORM_WIN32s        0
#define VER_PLATFORM_WIN32_WINDOWS 1
#define VER_PLATFORM_WIN32_NT      2
#endif
typedef struct _OSVERSIONINFOA {
  DWORD dwOSVersionInfoSize;
  DWORD dwMajorVersion;
  DWORD dwMinorVersion;
  DWORD dwBuildNumber;
  DWORD dwPlatformId;
  CHAR  szCSDVersion[128];
} OSVERSIONINFOA, OSVERSIONINFO, *POSVERSIONINFOA, *LPOSVERSIONINFOA, *POSVERSIONINFO, *LPOSVERSIONINFO;
typedef struct _OSVERSIONINFOW {
  DWORD dwOSVersionInfoSize;
  DWORD dwMajorVersion;
  DWORD dwMinorVersion;
  DWORD dwBuildNumber;
  DWORD dwPlatformId;
  WCHAR szCSDVersion[128];
} OSVERSIONINFOW, *POSVERSIONINFOW, *LPOSVERSIONINFOW;
// Report a Windows-NT-class platform (so the engine takes its non-Win9x path).
inline BOOL GetVersionEx(OSVERSIONINFOA *info)
{
  if (!info) return FALSE;
  info->dwMajorVersion = 5; info->dwMinorVersion = 1; // pretend XP-ish
  info->dwBuildNumber  = 2600;
  info->dwPlatformId   = VER_PLATFORM_WIN32_NT;
  info->szCSDVersion[0] = 0;
  return TRUE;
}
inline BOOL GetVersionExA(OSVERSIONINFOA *info) { return GetVersionEx(info); }
inline DWORD GetVersion() { return 0x0A280105u; } // 5.1 build 2600 packed

// --- Locale / date / time formatting. --------------------------------------
// The engine asks the OS to format a SYSTEMTIME into a localized date/time
// string. We return a fixed en-US-style formatting; this is display-only.
#ifndef LOCALE_USER_DEFAULT
#define LOCALE_USER_DEFAULT       0x0400
#define LOCALE_SYSTEM_DEFAULT     0x0800
#define LOCALE_SISO639LANGNAME    0x0059
#define LOCALE_SISO3166CTRYNAME   0x005A
#define LOCALE_SENGLANGUAGE       0x1001
#define LOCALE_SENGCOUNTRY        0x1002
#endif
#ifndef DATE_SHORTDATE
#define DATE_SHORTDATE   0x00000001u
#define DATE_LONGDATE    0x00000002u
#endif
#ifndef TIME_NOSECONDS
#define TIME_NOMINUTESORSECONDS 0x00000001u
#define TIME_NOSECONDS          0x00000002u
#define TIME_NOTIMEMARKER       0x00000004u
#define TIME_FORCE24HOURFORMAT  0x00000008u
#endif
inline int GetDateFormatA(unsigned /*locale*/, DWORD /*flags*/, const SYSTEMTIME *st,
                          const char * /*fmt*/, char *out, int cch)
{
  if (!out || cch <= 0) return 0;
  int n = st ? ::snprintf(out, (size_t)cch, "%02u/%02u/%04u",
                          st->wMonth, st->wDay, st->wYear)
             : (::snprintf(out, (size_t)cch, "%s", ""), 0);
  return n > 0 ? n + 1 : 0; // Win32 returns chars written incl. NUL
}
inline int GetDateFormat(unsigned l, DWORD f, const SYSTEMTIME *st, const char *fmt, char *out, int cch)
{ return GetDateFormatA(l, f, st, fmt, out, cch); }
inline int GetDateFormatW(unsigned /*locale*/, DWORD /*flags*/, const SYSTEMTIME *st,
                          const WCHAR * /*fmt*/, WCHAR *out, int cch)
{
  if (!out || cch <= 0) return 0;
  char tmp[64];
  if (st) ::snprintf(tmp, sizeof(tmp), "%02u/%02u/%04u", st->wMonth, st->wDay, st->wYear);
  else tmp[0] = 0;
  int i = 0; for (; tmp[i] && i < cch - 1; ++i) out[i] = (WCHAR)tmp[i];
  out[i] = 0;
  return i + 1;
}
inline int GetTimeFormatA(unsigned /*locale*/, DWORD /*flags*/, const SYSTEMTIME *st,
                          const char * /*fmt*/, char *out, int cch)
{
  if (!out || cch <= 0) return 0;
  int n = st ? ::snprintf(out, (size_t)cch, "%02u:%02u", st->wHour, st->wMinute)
             : (::snprintf(out, (size_t)cch, "%s", ""), 0);
  return n > 0 ? n + 1 : 0;
}
inline int GetTimeFormat(unsigned l, DWORD f, const SYSTEMTIME *st, const char *fmt, char *out, int cch)
{ return GetTimeFormatA(l, f, st, fmt, out, cch); }
inline int GetTimeFormatW(unsigned /*locale*/, DWORD /*flags*/, const SYSTEMTIME *st,
                          const WCHAR * /*fmt*/, WCHAR *out, int cch)
{
  if (!out || cch <= 0) return 0;
  char tmp[32];
  if (st) ::snprintf(tmp, sizeof(tmp), "%02u:%02u", st->wHour, st->wMinute);
  else tmp[0] = 0;
  int i = 0; for (; tmp[i] && i < cch - 1; ++i) out[i] = (WCHAR)tmp[i];
  out[i] = 0;
  return i + 1;
}
inline int GetLocaleInfoA(unsigned /*locale*/, DWORD /*lctype*/, char *out, int cch)
{
  // Return a fixed en-US value. TODO(macos): query CFLocale for real values.
  if (out && cch > 0) ::snprintf(out, (size_t)cch, "US");
  return out ? (int)::strlen(out) + 1 : 0;
}
inline int GetLocaleInfo(unsigned l, DWORD t, char *out, int cch) { return GetLocaleInfoA(l, t, out, cch); }

// --- FormatMessage. --------------------------------------------------------
#ifndef FORMAT_MESSAGE_ALLOCATE_BUFFER
#define FORMAT_MESSAGE_ALLOCATE_BUFFER 0x00000100u
#define FORMAT_MESSAGE_IGNORE_INSERTS  0x00000200u
#define FORMAT_MESSAGE_FROM_STRING     0x00000400u
#define FORMAT_MESSAGE_FROM_HMODULE    0x00000800u
#define FORMAT_MESSAGE_FROM_SYSTEM     0x00001000u
#define FORMAT_MESSAGE_ARGUMENT_ARRAY  0x00002000u
#endif
inline DWORD FormatMessageA(DWORD flags, const void * /*src*/, DWORD msgId,
                            DWORD /*langId*/, char *buf, DWORD size, va_list * /*args*/)
{
  // Map the error id through strerror; behaviour-only diagnostic text.
  const char *msg = ::strerror((int)msgId);
  if (flags & FORMAT_MESSAGE_ALLOCATE_BUFFER) {
    // Caller passes &(char*) reinterpreted as char*; allocate and store.
    char **out = (char **)buf;
    if (out) { *out = ::strdup(msg ? msg : ""); return (DWORD)(*out ? ::strlen(*out) : 0); }
    return 0;
  }
  if (!buf || !size) return 0;
  ::strncpy(buf, msg ? msg : "", size);
  buf[size - 1] = 0;
  return (DWORD)::strlen(buf);
}
inline DWORD FormatMessage(DWORD f, const void *s, DWORD m, DWORD l, char *b, DWORD sz, va_list *a)
{ return FormatMessageA(f, s, m, l, b, sz, a); }

// --- Memory status. --------------------------------------------------------
typedef struct _MEMORYSTATUS {
  DWORD  dwLength;
  DWORD  dwMemoryLoad;
  size_t dwTotalPhys;
  size_t dwAvailPhys;
  size_t dwTotalPageFile;
  size_t dwAvailPageFile;
  size_t dwTotalVirtual;
  size_t dwAvailVirtual;
} MEMORYSTATUS, *LPMEMORYSTATUS;
inline void GlobalMemoryStatus(MEMORYSTATUS *ms)
{
  if (!ms) return;
  ::memset(ms, 0, sizeof(*ms));
  ms->dwLength = sizeof(*ms);
  // Report a plausible 4GB machine; only used for "is there enough RAM" gating.
  // TODO(macos): query sysctl(HW_MEMSIZE) for the real figure.
  ms->dwTotalPhys     = (size_t)4 * 1024 * 1024 * 1024;
  ms->dwAvailPhys     = (size_t)2 * 1024 * 1024 * 1024;
  ms->dwTotalVirtual  = ms->dwTotalPhys;
  ms->dwAvailVirtual  = ms->dwAvailPhys;
  ms->dwTotalPageFile = ms->dwTotalPhys;
  ms->dwAvailPageFile = ms->dwAvailPhys;
}

// --- Misc time / input. ----------------------------------------------------
inline DWORD GetCurrentTime() { return (DWORD)(::clock() * 1000 / CLOCKS_PER_SEC); }
inline UINT  GetDoubleClickTime() { return 500; } // ms, Windows default

// --- Filesystem helpers used by SaveGame. ----------------------------------
inline BOOL SetCurrentDirectory(const char *path)
{ return (path && ::chdir(osdep_compat_detail::np(path)) == 0) ? TRUE : FALSE; }
inline BOOL SetCurrentDirectoryA(const char *path) { return SetCurrentDirectory(path); }
inline BOOL DeleteFile(const char *path)
{ return (path && ::unlink(osdep_compat_detail::np(path)) == 0) ? TRUE : FALSE; }
inline BOOL DeleteFileA(const char *path) { return DeleteFile(path); }

// --- Command line. ---------------------------------------------------------
// The real process command line is not reconstructed here; callers only need a
// non-null string. TODO(macos): stash argv at startup if exact text is needed.
inline char *GetCommandLineA() { static char s_empty[1] = {0}; return s_empty; }
inline char *GetCommandLine()  { return GetCommandLineA(); }

// --- COM task allocator (SHGetKnownFolderPath partner). --------------------
inline void CoTaskMemFree(void *p) { ::free(p); }

// --- Keyboard layout (IMEManager / Keyboard.cpp). --------------------------
#ifndef _HKL_DEFINED
#define _HKL_DEFINED
typedef HANDLE HKL;
#endif
inline HKL GetKeyboardLayout(DWORD /*threadId*/) { return (HKL)(intptr_t)0x0409; } // en-US
inline int GetKeyboardLayoutList(int /*n*/, HKL * /*list*/) { return 0; }
inline UINT GetOEMCP() { return 437; }
inline UINT GetACP() { return 1252; }

// --- Wide module path. -----------------------------------------------------
inline DWORD GetModuleFileNameW(HMODULE /*mod*/, WCHAR *out, DWORD size)
{
  if (!out || !size) return 0;
  char tmp[PATH_MAX];
  DWORD n = GetModuleFileName(nullptr, tmp, sizeof(tmp));
  DWORD i = 0; for (; i < n && i < size - 1; ++i) out[i] = (WCHAR)tmp[i];
  out[i] = 0;
  return i;
}

// --- GDI font resources (no-op; no GDI on macOS). --------------------------
inline int  AddFontResource(const char * /*path*/)    { return 1; }
inline int  AddFontResourceA(const char *p)           { return AddFontResource(p); }
inline BOOL RemoveFontResource(const char * /*path*/) { return TRUE; }
inline BOOL RemoveFontResourceA(const char *p)        { return RemoveFontResource(p); }

#ifndef ERROR_ALREADY_EXISTS
#define ERROR_ALREADY_EXISTS 183L
#endif
#ifndef ERROR_SUCCESS
#define ERROR_SUCCESS 0L
#endif

// --- MSVC low-level I/O spellings (_close / _O_* / _P_NOWAIT). --------------
#ifndef _O_RDONLY
#define _O_RDONLY  O_RDONLY
#define _O_WRONLY  O_WRONLY
#define _O_RDWR    O_RDWR
#define _O_CREAT   O_CREAT
#define _O_TRUNC   O_TRUNC
#define _O_APPEND  O_APPEND
#define _O_BINARY  0
#define _O_TEXT    0
#endif
#ifndef _S_IFDIR
#define _S_IFDIR   S_IFDIR
#define _S_IFREG   S_IFREG
#endif
#ifndef _P_WAIT
#define _P_WAIT    0
#define _P_NOWAIT  1
#define _P_OVERLAY 2
#endif
inline int _close(int fd) { return ::close(fd); }
inline int _open(const char *path, int flags, int mode = 0644) { return ::open(path, flags, mode); }
inline int _read(int fd, void *buf, unsigned n)  { return (int)::read(fd, buf, n); }
inline int _write(int fd, const void *buf, unsigned n) { return (int)::write(fd, buf, n); }

// --- _spawnl: spawn a child process (compile-only stub). -------------------
// Variadic argv-list process spawn. The macOS port does not spawn child
// processes here; report failure. TODO(macos): posix_spawn if ever needed.
inline intptr_t _spawnl(int /*mode*/, const char * /*path*/, const char * /*arg0*/, ...)
{ return -1; }

// --- FormatMessageW (wide sibling of FormatMessageA). ----------------------
inline DWORD FormatMessageW(DWORD flags, const void * /*src*/, DWORD msgId,
                            DWORD /*langId*/, WCHAR *buf, DWORD size, va_list * /*args*/)
{
  const char *msg = ::strerror((int)msgId);
  if (flags & FORMAT_MESSAGE_ALLOCATE_BUFFER) {
    WCHAR **out = (WCHAR **)buf;
    if (out) {
      size_t n = msg ? ::strlen(msg) : 0;
      WCHAR *w = (WCHAR *)::malloc((n + 1) * sizeof(WCHAR));
      for (size_t i = 0; i < n; ++i) w[i] = (WCHAR)msg[i];
      w[n] = 0; *out = w; return (DWORD)n;
    }
    return 0;
  }
  if (!buf || !size) return 0;
  DWORD i = 0; for (; msg && msg[i] && i < size - 1; ++i) buf[i] = (WCHAR)msg[i];
  buf[i] = 0;
  return i;
}

// --- GetModuleHandleW (wide). ----------------------------------------------
inline HMODULE GetModuleHandleW(const WCHAR * /*name*/) { return GetModuleHandle(nullptr); }

// ---------------------------------------------------------------------------
// Process spawning + anonymous pipes + job objects (WorkerProcess.cpp).
//
// WorkerProcess launches a helper executable and reads its stdout through a
// pipe, optionally placing it in a job so it dies with the parent. On macOS the
// port does not yet spawn helper processes, so CreateProcessW fails cleanly and
// the worker is treated as "did not start". The pipe/job shims exist so the
// surrounding code compiles. TODO(macos): posix_spawn + pipe() if helper
// processes are ever needed.
// ---------------------------------------------------------------------------
#ifndef _SECURITY_ATTRIBUTES_DEFINED
#define _SECURITY_ATTRIBUTES_DEFINED
typedef struct _SECURITY_ATTRIBUTES {
  DWORD  nLength;
  void  *lpSecurityDescriptor;
  BOOL   bInheritHandle;
} SECURITY_ATTRIBUTES, *PSECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;
#endif

typedef struct _STARTUPINFOW {
  DWORD  cb;
  WCHAR *lpReserved;
  WCHAR *lpDesktop;
  WCHAR *lpTitle;
  DWORD  dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
  DWORD  dwFillAttribute, dwFlags;
  WORD   wShowWindow, cbReserved2;
  BYTE  *lpReserved2;
  HANDLE hStdInput, hStdOutput, hStdError;
} STARTUPINFOW, *LPSTARTUPINFOW;
typedef STARTUPINFOW STARTUPINFOA, STARTUPINFO, *LPSTARTUPINFOA, *LPSTARTUPINFO;

typedef struct _PROCESS_INFORMATION {
  HANDLE hProcess;
  HANDLE hThread;
  DWORD  dwProcessId;
  DWORD  dwThreadId;
} PROCESS_INFORMATION, *PPROCESS_INFORMATION, *LPPROCESS_INFORMATION;

#ifndef STARTF_USESTDHANDLES
#define STARTF_USESHOWWINDOW    0x00000001u
#define STARTF_USESTDHANDLES    0x00000100u
#define STARTF_FORCEOFFFEEDBACK 0x00000080u
#endif
#ifndef HANDLE_FLAG_INHERIT
#define HANDLE_FLAG_INHERIT            0x00000001u
#define HANDLE_FLAG_PROTECT_FROM_CLOSE 0x00000002u
#endif

inline BOOL CreatePipe(HANDLE *readH, HANDLE *writeH, SECURITY_ATTRIBUTES * /*sa*/, DWORD /*size*/)
{
  int fds[2];
  if (::pipe(fds) != 0) return FALSE;
  if (readH)  *readH  = osdep_compat_detail::fd_to_handle(fds[0]);
  if (writeH) *writeH = osdep_compat_detail::fd_to_handle(fds[1]);
  return TRUE;
}
inline BOOL SetHandleInformation(HANDLE, DWORD, DWORD) { return TRUE; }

inline BOOL CreateProcessW(const WCHAR * /*app*/, WCHAR * /*cmdLine*/,
                           SECURITY_ATTRIBUTES * /*procAttr*/, SECURITY_ATTRIBUTES * /*threadAttr*/,
                           BOOL /*inherit*/, DWORD /*flags*/, void * /*env*/,
                           const WCHAR * /*curDir*/, STARTUPINFOW * /*si*/, PROCESS_INFORMATION *pi)
{
  // TODO(macos): no child-process spawning yet -> report failure.
  if (pi) ::memset(pi, 0, sizeof(*pi));
  return FALSE;
}
inline BOOL GetExitCodeProcess(HANDLE /*proc*/, DWORD *code) { if (code) *code = 0; return TRUE; }

// PeekNamedPipe over an anonymous pipe fd: report 0 bytes available (and success
// so the caller keeps polling without blocking). TODO(macos): FIONREAD probe.
inline BOOL PeekNamedPipe(HANDLE, void *, DWORD, DWORD *read, DWORD *avail, DWORD *left)
{ if (read) *read = 0; if (avail) *avail = 0; if (left) *left = 0; return FALSE; }

inline BOOL TerminateThread(HANDLE, DWORD) { return TRUE; } // TODO(macos): pthread_cancel if needed

// Job objects: process-grouping for kill-on-parent-exit. No analogue used on
// macOS; CreateJobObjectW returns null so the engine skips job assignment.
#ifndef JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
#define JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE 0x00002000u
#endif
typedef int JOBOBJECTINFOCLASS;
#ifndef JobObjectExtendedLimitInformation
enum { JobObjectExtendedLimitInformation = 9 };
#endif
typedef struct _JOBOBJECT_BASIC_LIMIT_INFORMATION {
  LARGE_INTEGER PerProcessUserTimeLimit;
  LARGE_INTEGER PerJobUserTimeLimit;
  DWORD     LimitFlags;
  size_t    MinimumWorkingSetSize;
  size_t    MaximumWorkingSetSize;
  DWORD     ActiveProcessLimit;
  uintptr_t Affinity;
  DWORD     PriorityClass;
  DWORD     SchedulingClass;
} JOBOBJECT_BASIC_LIMIT_INFORMATION;
typedef struct _IO_COUNTERS {
  unsigned long long ReadOperationCount, WriteOperationCount, OtherOperationCount;
  unsigned long long ReadTransferCount, WriteTransferCount, OtherTransferCount;
} IO_COUNTERS;
typedef struct _JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
  JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
  IO_COUNTERS IoInfo;
  size_t ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
} JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
inline HANDLE CreateJobObjectW(SECURITY_ATTRIBUTES *, const WCHAR *) { return nullptr; }
inline HANDLE CreateJobObjectA(SECURITY_ATTRIBUTES *, const char *)  { return nullptr; }
inline BOOL SetInformationJobObject(HANDLE, JOBOBJECTINFOCLASS, void *, DWORD) { return FALSE; }
inline BOOL AssignProcessToJobObject(HANDLE, HANDLE) { return FALSE; }

// ---------------------------------------------------------------------------
// Window class / message pump / paint (WinMain.cpp, Win32GameEngine.cpp).
//
// There is no native window or message loop on macOS yet (SDL arrives later),
// so the window-class registration is a no-op, the message pump never produces
// messages, and the paint/GDI calls are inert. The WndProc itself still compiles
// and is callable; it just never receives real OS events.
// TODO(macos): real impl needs an SDL window + event translation to WM_* msgs.
// ---------------------------------------------------------------------------
#ifndef _T
#define _T(x)   x
#endif
#ifndef TEXT
#define TEXT(x) x
#endif

#ifndef CS_VREDRAW
#define CS_VREDRAW   0x0001
#define CS_HREDRAW   0x0002
#define CS_DBLCLKS   0x0008
#define CS_OWNDC     0x0020
#define CS_CLASSDC   0x0040
#define CS_PARENTDC  0x0080
#endif
#ifndef WM_ERASEBKGND
#define WM_ERASEBKGND 0x0014
#endif
#ifndef BLACK_BRUSH
#define WHITE_BRUSH  0
#define BLACK_BRUSH  4
#define NULL_BRUSH   5
#endif
#ifndef MAKEINTRESOURCE
#define MAKEINTRESOURCE(i) ((const char *)(uintptr_t)((WORD)(i)))
#define MAKEINTRESOURCEW(i) ((const WCHAR *)(uintptr_t)((WORD)(i)))
#endif
// SetErrorMode flags (Win32GameEngine suppresses the critical-error dialog).
#ifndef SEM_FAILCRITICALERRORS
#define SEM_FAILCRITICALERRORS     0x0001u
#define SEM_NOGPFAULTERRORBOX      0x0002u
#define SEM_NOALIGNMENTFAULTEXCEPT 0x0004u
#define SEM_NOOPENFILEERRORBOX     0x8000u
#endif
inline UINT SetErrorMode(UINT /*mode*/) { return 0; }

typedef LRESULT (CALLBACK *WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct tagWNDCLASSA {
  UINT      style;
  WNDPROC   lpfnWndProc;
  int       cbClsExtra;
  int       cbWndExtra;
  HINSTANCE hInstance;
  HICON     hIcon;
  HCURSOR   hCursor;
  HBRUSH    hbrBackground;
  const char *lpszMenuName;
  const char *lpszClassName;
} WNDCLASSA, *PWNDCLASSA, *LPWNDCLASSA;
typedef WNDCLASSA WNDCLASS, *PWNDCLASS, *LPWNDCLASS;

typedef struct tagMSG {
  HWND   hwnd;
  UINT   message;
  WPARAM wParam;
  LPARAM lParam;
  DWORD  time;
  POINT  pt;
} MSG, *PMSG, *LPMSG;

typedef struct tagPAINTSTRUCT {
  HDC  hdc;
  BOOL fErase;
  RECT rcPaint;
  BOOL fRestore;
  BOOL fIncUpdate;
  BYTE rgbReserved[32];
} PAINTSTRUCT, *PPAINTSTRUCT, *LPPAINTSTRUCT;

inline ATOM RegisterClass(const WNDCLASS * /*wc*/)  { return (ATOM)1; }
inline ATOM RegisterClassA(const WNDCLASS *wc)      { return RegisterClass(wc); }
inline BOOL UnregisterClass(const char *, HINSTANCE){ return TRUE; }
inline HWND CreateWindow(const char *, const char *, DWORD, int, int, int, int,
                         HWND, HMENU, HINSTANCE, void *) { return nullptr; }
inline HWND CreateWindowEx(DWORD, const char *, const char *, DWORD, int, int, int, int,
                           HWND, HMENU, HINSTANCE, void *) { return nullptr; }
inline LRESULT DefWindowProc(HWND, UINT, WPARAM, LPARAM) { return 0; }
inline LRESULT DefWindowProcA(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProc(h, m, w, l); }
inline void PostQuitMessage(int /*exitCode*/) { }
inline BOOL DestroyWindow(HWND) { return TRUE; }
inline LRESULT SendMessage(HWND, UINT, WPARAM, LPARAM) { return 0; }
inline BOOL PostMessage(HWND, UINT, WPARAM, LPARAM) { return TRUE; }

// Message pump: no OS messages on macOS yet -> the queue is always empty.
inline BOOL PeekMessage(MSG *msg, HWND, UINT, UINT, UINT) { if (msg) ::memset(msg, 0, sizeof(*msg)); return FALSE; }
inline BOOL PeekMessageA(MSG *msg, HWND h, UINT a, UINT b, UINT c) { return PeekMessage(msg, h, a, b, c); }
inline BOOL GetMessage(MSG *msg, HWND, UINT, UINT) { if (msg) ::memset(msg, 0, sizeof(*msg)); return FALSE; }
inline BOOL TranslateMessage(const MSG *) { return FALSE; }
inline LRESULT DispatchMessage(const MSG *) { return 0; }
inline BOOL TranslateAccelerator(HWND, HACCEL, MSG *) { return FALSE; }

// Icons / cursors / menus (resource loads -> null; no resources on macOS).
inline HICON   LoadIcon(HINSTANCE, const char *)   { return nullptr; }
inline HCURSOR LoadCursor(HINSTANCE, const char *) { return nullptr; }
inline HMENU   LoadMenu(HINSTANCE, const char *)   { return nullptr; }
inline HBRUSH  GetStockObject(int)                 { return nullptr; }

// Paint / DC save-restore: inert (no GDI surface).
inline HDC  BeginPaint(HWND, PAINTSTRUCT *ps) { if (ps) ::memset(ps, 0, sizeof(*ps)); return nullptr; }
inline BOOL EndPaint(HWND, const PAINTSTRUCT *) { return TRUE; }
inline int  SaveDC(HDC)            { return 1; }
inline BOOL RestoreDC(HDC, int)    { return TRUE; }
inline BOOL InvalidateRect(HWND, const RECT *, BOOL) { return TRUE; }
inline BOOL ValidateRect(HWND, const RECT *)         { return TRUE; }
inline HWND SetFocus(HWND)         { return nullptr; }
inline HWND SetCapture(HWND)       { return nullptr; }
inline BOOL ReleaseCapture()       { return TRUE; }
inline BOOL SetForegroundWindow(HWND) { return TRUE; }
inline HWND FindWindow(const char *, const char *)  { return nullptr; }
inline HWND FindWindowA(const char *c, const char *w) { return FindWindow(c, w); }

// ShowWindow nCmdShow codes.
#ifndef SW_SHOW
#define SW_HIDE            0
#define SW_SHOWNORMAL      1
#define SW_NORMAL          1
#define SW_SHOWMINIMIZED   2
#define SW_SHOWMAXIMIZED   3
#define SW_MAXIMIZE        3
#define SW_SHOWNOACTIVATE  4
#define SW_SHOW            5
#define SW_MINIMIZE        6
#define SW_RESTORE         9
#define SW_SHOWDEFAULT     10
#endif

// LoadImage + flags (WinMain loads a splash bitmap from file). No GDI image
// loading on macOS yet -> returns null; the splash is simply not shown.
// TODO(macos): real impl loads via CGImage / a texture.
#ifndef IMAGE_BITMAP
#define IMAGE_BITMAP  0
#define IMAGE_ICON    1
#define IMAGE_CURSOR  2
#endif
#ifndef LR_LOADFROMFILE
#define LR_DEFAULTCOLOR  0x0000
#define LR_MONOCHROME    0x0001
#define LR_LOADFROMFILE  0x0010
#define LR_CREATEDIBSECTION 0x2000
#define LR_SHARED        0x8000
#define LR_DEFAULTSIZE   0x0040
#endif
inline HANDLE LoadImage(HINSTANCE, const char *, UINT, int, int, UINT) { return nullptr; }
inline HANDLE LoadImageA(HINSTANCE h, const char *n, UINT t, int x, int y, UINT f)
{ return LoadImage(h, n, t, x, y, f); }

#endif // !_WIN32
