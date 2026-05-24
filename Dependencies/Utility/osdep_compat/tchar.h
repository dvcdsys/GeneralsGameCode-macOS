#pragma once
// <tchar.h> shim for non-Windows builds.
//
// The TCHAR family is the Win32 "generic-text" layer that resolves to either
// the ANSI (char) or wide (wchar_t) API depending on _UNICODE. This port builds
// the ANSI variant, so every _t* maps onto the plain narrow CRT function.
#ifndef _WIN32

#include <cstring>
#include <cstdio>
#include <cstdlib>

#ifndef _TCHAR_DEFINED
#define _TCHAR_DEFINED
typedef char TCHAR, _TCHAR;
typedef char TBYTE;
#endif

#ifndef _T
#define _T(x)    x
#define _TEXT(x) x
#define TEXT(x)  x
#endif

// Narrow-CRT mappings for the generic-text routines actually referenced.
#ifndef _tcslen
#define _tcslen   strlen
#define _tcscpy   strcpy
#define _tcsncpy  strncpy
#define _tcscat   strcat
#define _tcscmp   strcmp
#define _tcsicmp  strcasecmp
#define _tcschr   strchr
#define _tcsrchr  strrchr
#define _tcsstr   strstr
#define _tcstok   strtok
#define _stprintf sprintf
#define _sntprintf snprintf
#define _tprintf  printf
#define _tfopen   fopen
#define _ttoi     atoi
#define _tcsdup   strdup
#endif

#endif // !_WIN32
