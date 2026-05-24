#pragma once
// <io.h> shim -> low-level POSIX file IO equivalents.
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <cstring>

#ifndef _WIN32
// _access -> POSIX access(). Mode 0 == existence check (maps to F_OK == 0).
inline int _access(const char *path, int mode) { return ::access(path, mode); }

// MSVC `struct _stat` / `_stat()` -> POSIX `struct stat` / `stat()`. The MSVC
// _stat layout is a subset (st_size / st_mode / st_mtime are the fields the
// engine reads), so the POSIX struct is a drop-in.
#ifndef _STAT_DEFINED_COMPAT
#define _STAT_DEFINED_COMPAT
struct _stat : public stat {};
inline int _stat(const char *path, struct _stat *buf)
{ return ::stat(path, static_cast<struct stat *>(buf)); }
#endif

// _chmod -> POSIX chmod. MSVC only honours _S_IREAD/_S_IWRITE; map to 0444/0644.
#ifndef _S_IREAD
#define _S_IREAD  0400
#define _S_IWRITE 0200
#define _S_IEXEC  0100
#endif
inline int _chmod(const char *path, int mode)
{
  // MSVC mode is a subset; translate the read/write bits to a POSIX mode.
  mode_t m = 0;
  if (mode & _S_IREAD)  m |= 0444;
  if (mode & _S_IWRITE) m |= 0200;
  if (m == 0) m = 0444;
  return ::chmod(path, m);
}

// _splitpath: decompose "drive:/dir/fname.ext" into its components. There are no
// drive letters on POSIX, so `drive` is always emptied. Any of the out buffers
// may be null (the caller does not want that piece). Buffers are assumed large
// enough (Win32 callers size them to _MAX_* like the real CRT).
inline void _splitpath(const char *path, char *drive, char *dir,
                       char *fname, char *ext)
{
  if (drive) drive[0] = '\0';
  if (dir)   dir[0]   = '\0';
  if (fname) fname[0] = '\0';
  if (ext)   ext[0]   = '\0';
  if (!path) return;

  // Find the last path separator (accept both '/' and '\\').
  const char *lastSlash = nullptr;
  for (const char *p = path; *p; ++p)
    if (*p == '/' || *p == '\\') lastSlash = p;

  const char *nameStart = lastSlash ? lastSlash + 1 : path;
  if (dir && lastSlash) {
    size_t n = (size_t)(nameStart - path);
    ::memcpy(dir, path, n);
    dir[n] = '\0';
  }

  // Split the file part on the last '.' (extension includes the dot).
  const char *dot = ::strrchr(nameStart, '.');
  if (fname) {
    size_t n = dot ? (size_t)(dot - nameStart) : ::strlen(nameStart);
    ::memcpy(fname, nameStart, n);
    fname[n] = '\0';
  }
  if (ext && dot) ::strcpy(ext, dot);
}
#endif
