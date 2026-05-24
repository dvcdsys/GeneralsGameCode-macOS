#pragma once
// <malloc.h> shim -> standard allocation + alloca.
#include <cstdlib>
#if defined(__APPLE__)
#include <alloca.h>
#endif
