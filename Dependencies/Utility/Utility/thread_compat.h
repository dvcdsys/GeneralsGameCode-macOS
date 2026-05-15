/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 TheSuperHackers
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// Thread / synchronization compatibility shim for non-Windows platforms.
// Provides minimal stand-ins for the Win32 idioms the codebase depends on:
//   - GetCurrentThreadId / Sleep
//   - CRITICAL_SECTION + Initialize/Enter/Leave/DeleteCriticalSection
//   - WaitForSingleObject (mutex-only flavor used by the engine)
#pragma once
#include <pthread.h>
#include <unistd.h>
#include <cstdint>

inline uint64_t GetCurrentThreadId()
{
  // pthread_self() returns an opaque type. Cast through uintptr_t to expose
  // it as a stable numeric id; matches what the Win32 API returns by contract.
  return reinterpret_cast<uintptr_t>(pthread_self());
}

inline void Sleep(int ms)
{
  usleep(ms * 1000);
}

// CRITICAL_SECTION shim. Mirrors Win32 semantics: recursive locking is allowed,
// initialization is required before use.
struct CRITICAL_SECTION
{
  pthread_mutex_t mutex;
};

inline void InitializeCriticalSection(CRITICAL_SECTION* cs)
{
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&cs->mutex, &attr);
  pthread_mutexattr_destroy(&attr);
}

inline void EnterCriticalSection(CRITICAL_SECTION* cs)
{
  pthread_mutex_lock(&cs->mutex);
}

inline void LeaveCriticalSection(CRITICAL_SECTION* cs)
{
  pthread_mutex_unlock(&cs->mutex);
}

inline void DeleteCriticalSection(CRITICAL_SECTION* cs)
{
  pthread_mutex_destroy(&cs->mutex);
}

// Minimal WaitForSingleObject shim — only the "wait forever on a mutex" form
// is used by the engine. Real Win32 handles aren't faked here; callers that
// need event/semaphore semantics should be ported to pthread_cond_t directly.
#ifndef INFINITE
#define INFINITE 0xFFFFFFFFu
#endif
#ifndef WAIT_OBJECT_0
#define WAIT_OBJECT_0 0u
#endif

inline unsigned WaitForSingleObject(CRITICAL_SECTION* cs, unsigned /*timeout_ms*/)
{
  pthread_mutex_lock(&cs->mutex);
  return WAIT_OBJECT_0;
}
