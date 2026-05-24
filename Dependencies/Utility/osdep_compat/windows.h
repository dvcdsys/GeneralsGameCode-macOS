#pragma once

// Minimal <windows.h> compatibility shim for non-Windows (macOS / Linux) builds.
//
// The WWVegas engine and the min-dx8-sdk headers `#include <windows.h>`
// pervasively. On MinGW/MSVC this comes from the platform SDK; there is no
// such header on macOS, so this shim supplies the Win32 *type vocabulary* and
// the harmless calling-convention / annotation macros the code relies on.
//
// Deliberate non-goals:
//   * This header does NOT define _WIN32. The engine keeps taking its _UNIX
//     code paths; we only make the Win32 type names resolve.
//   * Fixed-width integer types are used so DWORD/LONG stay 32-bit on LP64
//     macOS (where `unsigned long` would wrongly be 64-bit).
//   * Function-level Win32 API (CreateWindowEx, kernel32, ...) is NOT declared
//     here; those are ported per-subsystem. Thread/critical-section/timer
//     shims already live in Utility/thread_compat.h and time_compat.h, pulled
//     in via compat.h below.

#ifndef _WIN32

#include <cstdint>
#include <cstddef>
#include <cstring>

// Pull in the existing compatibility layer (string/mem/time/thread shims,
// __forceinline, __cdecl, _MAX_PATH, CRITICAL_SECTION, etc.).
#include "Utility/compat.h"

// ---------------------------------------------------------------------------
// Calling-convention / annotation macros -> no-ops on a native ABI.
// ---------------------------------------------------------------------------
#ifndef WINAPI
#define WINAPI
#endif
#ifndef APIENTRY
#define APIENTRY
#endif
#ifndef CALLBACK
#define CALLBACK
#endif
#ifndef WINAPIV
#define WINAPIV
#endif
#ifndef WINBASEAPI
#define WINBASEAPI
#endif
#ifndef WINUSERAPI
#define WINUSERAPI
#endif
#ifndef __stdcall
#define __stdcall
#endif
#ifndef _stdcall
#define _stdcall
#endif
#ifndef __fastcall
#define __fastcall
#endif
#ifndef PASCAL
#define PASCAL
#endif
#ifndef FAR
#define FAR
#endif
#ifndef NEAR
#define NEAR
#endif
#ifndef CONST
#define CONST const
#endif
#ifndef IN
#define IN
#endif
#ifndef OUT
#define OUT
#endif
#ifndef OPTIONAL
#define OPTIONAL
#endif
#ifndef DECLSPEC_IMPORT
#define DECLSPEC_IMPORT
#endif

// Pretend a modern Windows SDK so version-gated legacy blocks in the DX8
// headers (e.g. the WINVER<0x0500 HMONITOR fallback) are skipped.
#ifndef WINVER
#define WINVER 0x0600
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
// Our HMONITOR is defined below; tell the SDK not to re-DECLARE_HANDLE it.
#ifndef HMONITOR_DECLARED
#define HMONITOR_DECLARED
#endif

// ---------------------------------------------------------------------------
// Fundamental integer / boolean types.
// ---------------------------------------------------------------------------
// NOTE: BYTE/WORD/DWORD/BOOL/UINT/USHORT/ULONG/LPCSTR are also typedef'd
// (ungated) in Core/.../WWLib/bittype.h. The definitions here keep the *same
// underlying type* as those, since C++ permits repeated identical typedefs but
// rejects conflicting ones. DWORD/ULONG follow the engine's historical
// `unsigned long` convention (64-bit on LP64 macOS — a latent width issue for
// serialization, tracked for a later phase, but not a compile blocker).
typedef int                 BOOL;
typedef unsigned char       BOOLEAN;
typedef unsigned char       BYTE;
typedef unsigned short      WORD;
typedef unsigned long       DWORD;
typedef uint64_t            DWORDLONG;
typedef uint64_t            QWORD;
typedef int32_t             LONG;
typedef unsigned long       ULONG;
typedef int64_t             LONGLONG;
typedef uint64_t            ULONGLONG;
typedef int16_t             SHORT;
typedef uint16_t            USHORT;
typedef int                 INT;
typedef unsigned int        UINT;
typedef unsigned char       UCHAR;
typedef char                CHAR;
typedef wchar_t             WCHAR;
typedef float               FLOAT;
typedef double              DOUBLE;
typedef uint16_t            ATOM;

// MSVC sized-integer keywords used throughout the engine.
#ifndef _MSC_VER
typedef int64_t             __int64;
typedef int32_t             __int32;
typedef int16_t             __int16;
typedef int8_t              __int8;
// The legacy profile/* code uses the non-standard single-underscore spelling
// "_int64" (not a real MSVC keyword either). Alias it to the 64-bit type so the
// many existing call sites compile unchanged on clang/arm64.
typedef int64_t             _int64;
// On MSVC __int64/_int64 are keywords, so "unsigned __int64" is valid. Here they
// are typedefs, so "unsigned __int64" is a syntax error. A handful of call sites
// (debug_debug, profile_funclevel) need the unsigned 64-bit form; provide named
// typedefs for them to use on the non-Windows path.
typedef uint64_t            UNSIGNED_INT64_COMPAT;
#endif

// Pointer-sized integral types.
typedef intptr_t            INT_PTR;
typedef uintptr_t           UINT_PTR;
typedef intptr_t            LONG_PTR;
typedef uintptr_t           ULONG_PTR;
typedef uintptr_t           DWORD_PTR;
typedef size_t              SIZE_T;
typedef intptr_t            SSIZE_T;

typedef ULONG_PTR           WPARAM;
typedef LONG_PTR            LPARAM;
typedef LONG_PTR            LRESULT;

// ---------------------------------------------------------------------------
// Void / pointer types.
// ---------------------------------------------------------------------------
#ifndef VOID
#define VOID void
#endif
typedef void*               PVOID;
typedef void*               LPVOID;
typedef const void*         LPCVOID;

typedef CHAR*               PSTR;
typedef CHAR*               LPSTR;
typedef const CHAR*         PCSTR;
typedef const CHAR*         LPCSTR;
typedef WCHAR*              PWSTR;
typedef WCHAR*              LPWSTR;
typedef const WCHAR*        PCWSTR;
typedef const WCHAR*        LPCWSTR;

typedef BYTE*               PBYTE;
typedef BYTE*               LPBYTE;
typedef WORD*               PWORD;
typedef WORD*               LPWORD;
typedef DWORD*              PDWORD;
typedef DWORD*              LPDWORD;
typedef INT*                PINT;
typedef INT*                LPINT;
typedef LONG*               PLONG;
typedef LONG*               LPLONG;
typedef UINT*               PUINT;
typedef BOOL*               PBOOL;
typedef BOOL*               LPBOOL;

// ---------------------------------------------------------------------------
// Handle types (opaque).
// ---------------------------------------------------------------------------
typedef void*               HANDLE;
typedef HANDLE*             PHANDLE;
typedef void*               HMODULE;
typedef void*               HINSTANCE;
typedef void*               HWND;
typedef void*               HDC;
typedef void*               HGLRC;
typedef void*               HBITMAP;
typedef void*               HICON;
typedef void*               HCURSOR;
typedef void*               HBRUSH;
typedef void*               HFONT;
typedef void*               HMENU;
typedef void*               HACCEL;
typedef void*               HKEY;
typedef HKEY*               PHKEY;
typedef void*               HGDIOBJ;
typedef void*               HPALETTE;
typedef void*               HRGN;
typedef void*               HMONITOR;
typedef void*               HGLOBAL;
typedef void*               HLOCAL;
typedef void*               HRSRC;

// ---------------------------------------------------------------------------
// TCHAR / text mappings (ANSI flavor; the engine is not built UNICODE here).
// ---------------------------------------------------------------------------
#ifndef _TCHAR_DEFINED
typedef CHAR                TCHAR;
typedef TCHAR*              LPTSTR;
typedef TCHAR*              PTSTR;
typedef const TCHAR*        LPCTSTR;
typedef const TCHAR*        PCTSTR;
#define _TCHAR_DEFINED
#endif

// ---------------------------------------------------------------------------
// Common boolean / null macros.
// ---------------------------------------------------------------------------
#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif
#ifndef NULL
#define NULL 0
#endif
#ifndef MAX_PATH
#define MAX_PATH 260
#endif

// ---------------------------------------------------------------------------
// Geometry / time structures.
// ---------------------------------------------------------------------------
typedef struct tagPOINT { LONG x; LONG y; } POINT, *PPOINT, *LPPOINT;
typedef struct tagSIZE  { LONG cx; LONG cy; } SIZE, *PSIZE, *LPSIZE;
typedef struct tagRECT  { LONG left; LONG top; LONG right; LONG bottom; } RECT, *PRECT, *LPRECT;
typedef struct tagPOINTS { SHORT x; SHORT y; } POINTS;

// Fixed-width fields here (not DWORD/LONG) so these stay true 64-bit unions
// regardless of the engine's `unsigned long` DWORD convention.
typedef union _LARGE_INTEGER {
    struct { uint32_t LowPart; int32_t HighPart; } u;
    struct { uint32_t LowPart; int32_t HighPart; };
    int64_t QuadPart;
} LARGE_INTEGER, *PLARGE_INTEGER;

typedef union _ULARGE_INTEGER {
    struct { uint32_t LowPart; uint32_t HighPart; } u;
    struct { uint32_t LowPart; uint32_t HighPart; };
    uint64_t QuadPart;
} ULARGE_INTEGER, *PULARGE_INTEGER;

typedef struct _FILETIME {
    DWORD dwLowDateTime;
    DWORD dwHighDateTime;
} FILETIME, *PFILETIME, *LPFILETIME;

typedef struct _SYSTEMTIME {
    WORD wYear; WORD wMonth; WORD wDayOfWeek; WORD wDay;
    WORD wHour; WORD wMinute; WORD wSecond; WORD wMilliseconds;
} SYSTEMTIME, *PSYSTEMTIME, *LPSYSTEMTIME;

typedef struct _GUID {
    DWORD Data1;
    WORD  Data2;
    WORD  Data3;
    BYTE  Data4[8];
} GUID;
typedef GUID  IID;
typedef GUID  CLSID;
typedef GUID* LPGUID;
typedef const GUID* LPCGUID;
typedef const GUID& REFGUID;
typedef const IID&  REFIID;
typedef const CLSID& REFCLSID;

// GUID equality (Win32 provides IsEqualGUID / operator==). Used by COM
// QueryInterface implementations to match an interface id.
#ifdef __cplusplus
inline bool operator==(const GUID& a, const GUID& b)
{
    return a.Data1 == b.Data1 && a.Data2 == b.Data2 && a.Data3 == b.Data3 &&
           __builtin_memcmp(a.Data4, b.Data4, sizeof(a.Data4)) == 0;
}
inline bool operator!=(const GUID& a, const GUID& b) { return !(a == b); }
#endif
// IID_IUnknown — the COM root interface id {00000000-0000-0000-C000-000000000046}.
#ifndef _IID_IUNKNOWN_DEFINED
#define _IID_IUNKNOWN_DEFINED
static const IID IID_IUnknown =
    { 0x00000000, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
#endif

// ---------------------------------------------------------------------------
// GDI types referenced by the DX8 SDK headers (declarations only).
// ---------------------------------------------------------------------------
typedef struct tagPALETTEENTRY {
    BYTE peRed; BYTE peGreen; BYTE peBlue; BYTE peFlags;
} PALETTEENTRY, *PPALETTEENTRY, *LPPALETTEENTRY;

typedef struct tagRGBQUAD {
    BYTE rgbBlue; BYTE rgbGreen; BYTE rgbRed; BYTE rgbReserved;
} RGBQUAD;

typedef struct _RGNDATAHEADER {
    DWORD dwSize; DWORD iType; DWORD nCount; DWORD nRgnSize; RECT rcBound;
} RGNDATAHEADER;

typedef struct _RGNDATA {
    RGNDATAHEADER rdh;
    char Buffer[1];
} RGNDATA, *PRGNDATA, *LPRGNDATA;

#define LF_FACESIZE 32
typedef struct tagLOGFONTA {
    LONG lfHeight; LONG lfWidth; LONG lfEscapement; LONG lfOrientation;
    LONG lfWeight; BYTE lfItalic; BYTE lfUnderline; BYTE lfStrikeOut;
    BYTE lfCharSet; BYTE lfOutPrecision; BYTE lfClipPrecision;
    BYTE lfQuality; BYTE lfPitchAndFamily; CHAR lfFaceName[LF_FACESIZE];
} LOGFONTA, *PLOGFONTA, *LPLOGFONTA;
typedef LOGFONTA LOGFONT;
typedef PLOGFONTA PLOGFONT;
typedef LPLOGFONTA LPLOGFONT;

typedef struct _POINTFLOAT { FLOAT x; FLOAT y; } POINTFLOAT, *PPOINTFLOAT;
typedef struct _GLYPHMETRICSFLOAT {
    FLOAT gmfBlackBoxX; FLOAT gmfBlackBoxY;
    POINTFLOAT gmfptGlyphOrigin;
    FLOAT gmfCellIncX; FLOAT gmfCellIncY;
} GLYPHMETRICSFLOAT, *PGLYPHMETRICSFLOAT, *LPGLYPHMETRICSFLOAT;

// ---------------------------------------------------------------------------
// HRESULT / COM result codes.
// ---------------------------------------------------------------------------
typedef LONG HRESULT;
#ifndef S_OK
#define S_OK            ((HRESULT)0L)
#endif
#ifndef S_FALSE
#define S_FALSE         ((HRESULT)1L)
#endif
#ifndef E_FAIL
#define E_FAIL          ((HRESULT)0x80004005L)
#endif
#ifndef E_INVALIDARG
#define E_INVALIDARG    ((HRESULT)0x80070057L)
#endif
#ifndef E_OUTOFMEMORY
#define E_OUTOFMEMORY   ((HRESULT)0x8007000EL)
#endif
#ifndef E_NOTIMPL
#define E_NOTIMPL       ((HRESULT)0x80004001L)
#endif
#ifndef E_NOINTERFACE
#define E_NOINTERFACE   ((HRESULT)0x80004002L)
#endif
#ifndef E_POINTER
#define E_POINTER       ((HRESULT)0x80004003L)
#endif
#ifndef MAKE_HRESULT
#define MAKE_HRESULT(sev, fac, code) \
    ((HRESULT)(((unsigned long)(sev) << 31) | ((unsigned long)(fac) << 16) | ((unsigned long)(code))))
#endif
// HRESULT severity and facility codes used with MAKE_HRESULT.
#ifndef SEVERITY_SUCCESS
#define SEVERITY_SUCCESS 0
#endif
#ifndef SEVERITY_ERROR
#define SEVERITY_ERROR   1
#endif
#ifndef FACILITY_WIN32
#define FACILITY_WIN32   7
#endif
#ifndef FACILITY_ITF
#define FACILITY_ITF     4
#endif
// Common HRESULT/OLE error values referenced by device code.
#ifndef E_ACCESSDENIED
#define E_ACCESSDENIED       ((HRESULT)0x80070005L)
#endif
#ifndef CLASS_E_NOAGGREGATION
#define CLASS_E_NOAGGREGATION ((HRESULT)0x80040110L)
#endif
#ifndef CLASS_E_CLASSNOTAVAILABLE
#define CLASS_E_CLASSNOTAVAILABLE ((HRESULT)0x80040111L)
#endif
#ifndef REGDB_E_CLASSNOTREG
#define REGDB_E_CLASSNOTREG  ((HRESULT)0x80040154L)
#endif
#ifndef SUCCEEDED
#define SUCCEEDED(hr)   (((HRESULT)(hr)) >= 0)
#endif
#ifndef FAILED
#define FAILED(hr)      (((HRESULT)(hr)) < 0)
#endif

// ---------------------------------------------------------------------------
// Memory helper macros.
// ---------------------------------------------------------------------------
#ifndef ZeroMemory
#define ZeroMemory(dest, len)        memset((dest), 0, (len))
#endif
#ifndef CopyMemory
#define CopyMemory(dest, src, len)   memcpy((dest), (src), (len))
#endif
#ifndef MoveMemory
#define MoveMemory(dest, src, len)   memmove((dest), (src), (len))
#endif
#ifndef FillMemory
#define FillMemory(dest, len, fill)  memset((dest), (fill), (len))
#endif

// ---------------------------------------------------------------------------
// MSVC __min/__max intrinsic macros.
// ---------------------------------------------------------------------------
#ifndef __min
#define __min(a, b) (((a) < (b)) ? (a) : (b))
#endif
#ifndef __max
#define __max(a, b) (((a) > (b)) ? (a) : (b))
#endif

// ---------------------------------------------------------------------------
// MAKE*/LO*/HI* word helpers.
// ---------------------------------------------------------------------------
#ifndef MAKEWORD
#define MAKEWORD(a, b)  ((WORD)(((BYTE)(a)) | ((WORD)((BYTE)(b))) << 8))
#endif
#ifndef MAKELONG
#define MAKELONG(a, b)  ((LONG)(((WORD)(a)) | ((DWORD)((WORD)(b))) << 16))
#endif
#ifndef LOWORD
#define LOWORD(l)       ((WORD)((DWORD_PTR)(l) & 0xffff))
#endif
#ifndef HIWORD
#define HIWORD(l)       ((WORD)(((DWORD_PTR)(l) >> 16) & 0xffff))
#endif
#ifndef LOBYTE
#define LOBYTE(w)       ((BYTE)((DWORD_PTR)(w) & 0xff))
#endif
#ifndef HIBYTE
#define HIBYTE(w)       ((BYTE)(((DWORD_PTR)(w) >> 8) & 0xff))
#endif

// ---------------------------------------------------------------------------
// Window-message and virtual-key constants. Referenced by the mouse/keyboard
// device translation code (Win32Mouse / W3DMouse / Win32DIKeyboard). Real input
// is routed through SDL in a later phase; these only need their canonical Win32
// values so the translation switch statements compile.
// ---------------------------------------------------------------------------
#ifndef WM_MOUSEMOVE
#define WM_MOUSEMOVE       0x0200
#define WM_LBUTTONDOWN     0x0201
#define WM_LBUTTONUP       0x0202
#define WM_LBUTTONDBLCLK   0x0203
#define WM_RBUTTONDOWN     0x0204
#define WM_RBUTTONUP       0x0205
#define WM_RBUTTONDBLCLK   0x0206
#define WM_MBUTTONDOWN     0x0207
#define WM_MBUTTONUP       0x0208
#define WM_MBUTTONDBLCLK   0x0209
#define WM_MOUSEWHEEL      0x020A
#endif
// Window lifecycle / focus / system messages referenced by WinMain.cpp's
// message pump and the IME / text-entry translation code. Real input is routed
// through SDL later; these only need canonical Win32 values to compile.
#ifndef WM_CREATE
#define WM_CREATE          0x0001
#define WM_DESTROY         0x0002
#define WM_MOVE            0x0003
#define WM_SIZE            0x0005
#define WM_ACTIVATE        0x0006
#define WM_SETFOCUS        0x0007
#define WM_KILLFOCUS       0x0008
#define WM_PAINT           0x000F
#define WM_CLOSE           0x0010
#define WM_QUERYENDSESSION 0x0011
#define WM_QUIT            0x0012
#define WM_ACTIVATEAPP     0x001C
#define WM_SETCURSOR       0x0020
#define WM_NCHITTEST       0x0084
#define WM_KEYDOWN         0x0100
#define WM_KEYUP           0x0101
#define WM_CHAR            0x0102
#define WM_SYSKEYDOWN      0x0104
#define WM_SYSKEYUP        0x0105
#define WM_SYSCHAR         0x0106
#define WM_SYSCOMMAND      0x0112
#define WM_POWERBROADCAST  0x0218
// IME messages.
#define WM_IME_STARTCOMPOSITION 0x010D
#define WM_IME_ENDCOMPOSITION   0x010E
#define WM_IME_COMPOSITION      0x010F
#define WM_IME_SETCONTEXT       0x0281
#define WM_IME_NOTIFY           0x0282
#define WM_IME_CONTROL          0x0283
#define WM_IME_COMPOSITIONFULL  0x0284
#define WM_IME_SELECT           0x0285
#define WM_IME_CHAR             0x0286
#endif
// WM_ACTIVATE wParam codes.
#ifndef WA_INACTIVE
#define WA_INACTIVE    0
#define WA_ACTIVE      1
#define WA_CLICKACTIVE 2
#endif
// WM_SYSCOMMAND wParam codes.
#ifndef SC_SIZE
#define SC_SIZE        0xF000
#define SC_MOVE        0xF010
#define SC_MINIMIZE    0xF020
#define SC_MAXIMIZE    0xF030
#define SC_KEYMENU     0xF100
#define SC_MONITORPOWER 0xF170
#define SC_SCREENSAVE  0xF140
#endif
// WM_NCHITTEST return codes.
#ifndef HTCLIENT
#define HTERROR     (-2)
#define HTNOWHERE   0
#define HTCLIENT    1
#define HTCAPTION   2
#endif
// PeekMessage / message-pump constants.
#ifndef PM_REMOVE
#define PM_NOREMOVE 0x0000
#define PM_REMOVE   0x0001
#endif
#ifndef VK_DELETE
#define VK_LBUTTON  0x01
#define VK_RBUTTON  0x02
#define VK_MBUTTON  0x04
#define VK_BACK     0x08
#define VK_TAB      0x09
#define VK_RETURN   0x0D
#define VK_SHIFT    0x10
#define VK_CONTROL  0x11
#define VK_MENU     0x12
#define VK_CAPITAL  0x14
#define VK_ESCAPE   0x1B
#define VK_SPACE    0x20
#define VK_PRIOR    0x21
#define VK_NEXT     0x22
#define VK_END      0x23
#define VK_HOME     0x24
#define VK_LEFT     0x25
#define VK_UP       0x26
#define VK_RIGHT    0x27
#define VK_DOWN     0x28
#define VK_INSERT   0x2D
#define VK_DELETE   0x2E
#define VK_F1       0x70
#define VK_F2       0x71
#define VK_F3       0x72
#define VK_F4       0x73
#define VK_F5       0x74
#define VK_F6       0x75
#define VK_F7       0x76
#define VK_F8       0x77
#define VK_F9       0x78
#define VK_F10      0x79
#define VK_F11      0x7A
#define VK_F12      0x7B
#endif

// ---------------------------------------------------------------------------
// POSIX-backed Win32 *API function* shims (file IO, GlobalAlloc, timers,
// console/pipe stubs, MessageBox, wsprintf, ...) for the debug/profile libs.
// Kept in a separate header to keep the type-vocabulary above readable.
// ---------------------------------------------------------------------------
#include "win32_api.h"

// File-backed Win32 registry API shim (RegOpenKeyEx/RegQueryValueEx/...).
#include "winreg.h"

// Input Method Manager (IME) shim (HIMC / Imm* / IMN_* / GCS_* / CS_*).
#include "imm.h"

// ---------------------------------------------------------------------------
// Structured-exception (SEH) status codes. There is no SEH on POSIX; these are
// referenced only by the crash-dump code (StackDump.cpp) to map a numeric
// exception code to a human-readable description. The values match winnt.h.
// ---------------------------------------------------------------------------
#ifndef EXCEPTION_ACCESS_VIOLATION
#define EXCEPTION_ACCESS_VIOLATION         0xC0000005u
#define EXCEPTION_DATATYPE_MISALIGNMENT    0x80000002u
#define EXCEPTION_BREAKPOINT               0x80000003u
#define EXCEPTION_SINGLE_STEP              0x80000004u
#define EXCEPTION_ARRAY_BOUNDS_EXCEEDED    0xC000008Cu
#define EXCEPTION_FLT_DENORMAL_OPERAND     0xC000008Du
#define EXCEPTION_FLT_DIVIDE_BY_ZERO       0xC000008Eu
#define EXCEPTION_FLT_INEXACT_RESULT       0xC000008Fu
#define EXCEPTION_FLT_INVALID_OPERATION    0xC0000090u
#define EXCEPTION_FLT_OVERFLOW             0xC0000091u
#define EXCEPTION_FLT_STACK_CHECK          0xC0000092u
#define EXCEPTION_FLT_UNDERFLOW            0xC0000093u
#define EXCEPTION_INT_DIVIDE_BY_ZERO       0xC0000094u
#define EXCEPTION_INT_OVERFLOW             0xC0000095u
#define EXCEPTION_PRIV_INSTRUCTION         0xC0000096u
#define EXCEPTION_IN_PAGE_ERROR            0xC0000006u
#define EXCEPTION_ILLEGAL_INSTRUCTION      0xC000001Du
#define EXCEPTION_NONCONTINUABLE_EXCEPTION 0xC0000025u
#define EXCEPTION_STACK_OVERFLOW           0xC00000FDu
#define EXCEPTION_INVALID_DISPOSITION      0xC0000026u
#endif

#endif // !_WIN32
