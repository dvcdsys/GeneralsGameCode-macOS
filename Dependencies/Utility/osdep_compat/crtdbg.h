#pragma once
// <crtdbg.h> shim -> CRT debug macros become no-ops / standard assert.
#include <cassert>
#ifndef _ASSERT
#define _ASSERT(expr)        ((void)0)
#endif
#ifndef _ASSERTE
#define _ASSERTE(expr)       ((void)0)
#endif
#ifndef _CrtCheckMemory
#define _CrtCheckMemory()    (1)
#endif
#ifndef _CrtSetDbgFlag
#define _CrtSetDbgFlag(f)    (0)
#endif
