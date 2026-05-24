#pragma once
// <direct.h> shim -> POSIX directory functions.
#ifndef _WIN32
#include <sys/stat.h>
#include <unistd.h>
inline int _mkdir(const char* p) { return ::mkdir(p, 0777); }
inline int _rmdir(const char* p) { return ::rmdir(p); }
inline int _chdir(const char* p) { return ::chdir(p); }
inline char* _getcwd(char* buf, int size) { return ::getcwd(buf, size); }
#endif
