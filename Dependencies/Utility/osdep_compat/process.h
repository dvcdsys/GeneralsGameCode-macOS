#pragma once
// <process.h> shim. Win32 _beginthreadex/_endthreadex live here on Windows;
// the engine's threading is ported via Utility/thread_compat.h. This stub keeps
// `#include <process.h>` resolving on non-Windows.
#include "Utility/thread_compat.h"
