#pragma once
// <excpt.h> shim for non-Windows builds.
//
// Provides the Win32 Structured Exception Handling (SEH) vocabulary as no-op
// definitions. The engine's SEH (__try/__except/__finally) is compiled out on
// non-Windows, but a few headers reference the EXCEPTION_* tokens and the
// _EXCEPTION_POINTERS type, so we model them here.
//
// TODO(macos): real crash handling (e.g. signal handlers / Mach exception
// ports) is a later phase; for now SEH is inert.
#ifndef _WIN32

#include "windows.h"

#ifndef EXCEPTION_EXECUTE_HANDLER
#define EXCEPTION_EXECUTE_HANDLER     1
#define EXCEPTION_CONTINUE_SEARCH     0
#define EXCEPTION_CONTINUE_EXECUTION (-1)
#endif

// SEH keywords map to plain (always-taken / never-taken) control flow so that
// any non-_WIN32 code that still uses them parses and runs the guarded block.
#ifndef _INC_EXCPT_KEYWORDS
#define _INC_EXCPT_KEYWORDS
#ifndef __try
#define __try            if (1)
#endif
#ifndef __except
#define __except(expr)   if (0)
#endif
#ifndef __finally
#define __finally        if (1)
#endif
#ifndef __leave
#define __leave
#endif
#endif

// EXCEPTION_POINTERS / _EXCEPTION_POINTERS are typedef'd in win32_api.h
// (pulled in by windows.h above), so they are already available here.

#ifndef GetExceptionCode
#define GetExceptionCode()         (0)
#define GetExceptionInformation()  ((struct _EXCEPTION_POINTERS *)0)
#endif

#endif // !_WIN32
