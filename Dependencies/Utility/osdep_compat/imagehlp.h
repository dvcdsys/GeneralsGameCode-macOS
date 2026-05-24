#pragma once

// Minimal <imagehlp.h> / DbgHelp compatibility shim for non-Windows builds.
//
// WWLib's DbgHelpLoader dynamically loads dbghelp.dll and exposes the symbol /
// stack-walking API (SymInitialize, StackWalk, SymGetSymFromAddr, ...). On
// macOS there is no dbghelp.dll, so the loader's dlopen of it simply fails and
// every wrapped call returns its "not loaded" default. This header only needs
// to supply the *type vocabulary* used in the function-pointer typedefs and the
// public method signatures; the structures are treated as opaque by the loader
// on the non-Windows path.
//
// NOTE: the minidump portion (MINIDUMP_*) lives behind RTS_ENABLE_CRASHDUMP,
// which is disabled in the macOS preset, so it is intentionally not modelled.
//
// TODO(macos): real crash symbolication would use the macOS backtrace_symbols /
// CoreSymbolication APIs instead.

#ifndef _WIN32

#include <windows.h>

// IMAGEHLP_SYMBOL / IMAGEHLP_LINE: only ever handled as out-pointers passed
// through to the (always-null on macOS) dbghelp function pointers.
typedef struct _IMAGEHLP_SYMBOL {
  DWORD SizeOfStruct;
  DWORD Address;
  DWORD Size;
  DWORD Flags;
  DWORD MaxNameLength;
  CHAR  Name[1];
} IMAGEHLP_SYMBOL, *PIMAGEHLP_SYMBOL;

typedef struct _IMAGEHLP_LINE {
  DWORD SizeOfStruct;
  PVOID Key;
  DWORD LineNumber;
  CHAR* FileName;
  DWORD Address;
} IMAGEHLP_LINE, *PIMAGEHLP_LINE;

// ADDRESS / STACKFRAME for StackWalk.
typedef enum { AddrMode1616, AddrMode1632, AddrModeReal, AddrModeFlat } ADDRESS_MODE;
typedef struct _ADDRESS {
  DWORD        Offset;
  WORD         Segment;
  ADDRESS_MODE Mode;
} ADDRESS, *LPADDRESS;
typedef struct _KDHELP {
  DWORD Thread; DWORD ThCallbackStack; DWORD NextCallback;
  DWORD FramePointer; DWORD KiCallUserMode; DWORD KeUserCallbackDispatcher;
  DWORD SystemRangeStart;
} KDHELP, *PKDHELP;
typedef struct _STACKFRAME {
  ADDRESS AddrPC;
  ADDRESS AddrReturn;
  ADDRESS AddrFrame;
  ADDRESS AddrStack;
  PVOID   FuncTableEntry;
  DWORD   Params[4];
  BOOL    Far;
  BOOL    Virtual;
  DWORD   Reserved[3];
  KDHELP  KdHelp;
} STACKFRAME, *LPSTACKFRAME;

// dbghelp callback function-pointer types (the loader only forwards these).
typedef BOOL  (WINAPI *PREAD_PROCESS_MEMORY_ROUTINE)(HANDLE, DWORD, PVOID, DWORD, PDWORD);
typedef PVOID (WINAPI *PFUNCTION_TABLE_ACCESS_ROUTINE)(HANDLE, DWORD);
typedef DWORD (WINAPI *PGET_MODULE_BASE_ROUTINE)(HANDLE, DWORD);
typedef DWORD (WINAPI *PTRANSLATE_ADDRESS_ROUTINE)(HANDLE, HANDLE, LPADDRESS);

// ---------------------------------------------------------------------------
// CONTEXT (CPU register snapshot) + StackWalk machine codes + SYMOPT flags.
//
// StackDump.cpp models an x86 register context. On arm64 macOS there is no
// dbghelp and the stack-walk path is dead (DbgHelpLoader::load() fails), so we
// only need the x86-shaped fields to exist for the code to compile. Reads of
// gsContext.Eip/Esp/Ebp return zero.
// TODO(macos): real backtraces would use backtrace()/CoreSymbolication.
// ---------------------------------------------------------------------------
#ifndef CONTEXT_FULL
typedef struct _CONTEXT {
  DWORD ContextFlags;
  DWORD Eip;
  DWORD Esp;
  DWORD Ebp;
  DWORD Eax, Ebx, Ecx, Edx, Esi, Edi;
  DWORD EFlags;
  DWORD SegCs, SegSs, SegDs, SegEs, SegFs, SegGs;
} CONTEXT, *PCONTEXT, *LPCONTEXT;
#define CONTEXT_FULL 0x00010007u
#endif

// EXCEPTION_RECORD / EXCEPTION_POINTERS: SEH crash context. There is no SEH on
// POSIX; the crash dumper only reads these fields, and the dump path is never
// reached on macOS (no SetUnhandledExceptionFilter delivery), so the contents
// are inert. The forward declaration in win32_api.h is completed here.
#ifndef _EXCEPTION_RECORD_DEFINED
#define _EXCEPTION_RECORD_DEFINED
#define EXCEPTION_MAXIMUM_PARAMETERS 15
typedef struct _EXCEPTION_RECORD {
  DWORD     ExceptionCode;
  DWORD     ExceptionFlags;
  struct _EXCEPTION_RECORD *ExceptionRecord;
  PVOID     ExceptionAddress;
  DWORD     NumberParameters;
  uintptr_t ExceptionInformation[EXCEPTION_MAXIMUM_PARAMETERS];
} EXCEPTION_RECORD, *PEXCEPTION_RECORD;
// Complete the _EXCEPTION_POINTERS forward-declared in win32_api.h.
struct _EXCEPTION_POINTERS {
  PEXCEPTION_RECORD ExceptionRecord;
  PCONTEXT          ContextRecord;
};
#endif

#ifndef IMAGE_FILE_MACHINE_I386
#define IMAGE_FILE_MACHINE_I386  0x014c
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#endif

#ifndef SYMOPT_DEFERRED_LOADS
#define SYMOPT_CASE_INSENSITIVE   0x00000001u
#define SYMOPT_UNDNAME            0x00000002u
#define SYMOPT_DEFERRED_LOADS     0x00000004u
#define SYMOPT_LOAD_LINES         0x00000010u
#define SYMOPT_OMAP_FIND_NEAREST  0x00000020u
#endif

// GetThreadContext: no per-thread register capture on macOS; zero the context.
inline BOOL GetThreadContext(HANDLE, CONTEXT *ctx)
{ if (ctx) { DWORD f = ctx->ContextFlags; ::memset(ctx, 0, sizeof(*ctx)); ctx->ContextFlags = f; } return FALSE; }

#endif // !_WIN32
