#pragma once
// <winsock.h> shim mapping the Win32 sockets API onto BSD sockets (macOS).
// Used by WWDownload (FTP/HTTP patch downloader). Winsock is largely
// source-compatible with BSD sockets; the differences are shimmed here.
#ifndef _WIN32
#include <windows.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

typedef int SOCKET;
#ifndef INVALID_SOCKET
#define INVALID_SOCKET (-1)
#endif
#ifndef SOCKET_ERROR
#define SOCKET_ERROR   (-1)
#endif

// Winsock startup/shutdown are no-ops on POSIX.
typedef struct WSAData { unsigned short wVersion; char szDescription[257]; } WSADATA, *LPWSADATA;
inline int  WSAStartup(unsigned short, LPWSADATA) { return 0; }
inline int  WSACleanup() { return 0; }
inline int  WSAGetLastError() { return errno; }
inline int  closesocket(SOCKET s) { return ::close(s); }

#ifndef MAKEWORD
#define MAKEWORD(a, b) ((WORD)(((BYTE)(a)) | ((WORD)((BYTE)(b))) << 8))
#endif
#ifndef FIONBIO
// ioctlsocket(FIONBIO) -> fcntl(O_NONBLOCK). The control word is unused by the
// shim below, but the symbol must exist for the call sites to compile.
#define FIONBIO 0x8004667E
#endif

// Winsock error codes -> POSIX errno equivalents (referenced by Download/FTP).
#ifndef WSAEWOULDBLOCK
#define WSAEWOULDBLOCK  EWOULDBLOCK
#endif
#ifndef WSAEINVAL
#define WSAEINVAL       EINVAL
#endif
#ifndef WSAEINPROGRESS
#define WSAEINPROGRESS  EINPROGRESS
#endif
#ifndef WSAECONNREFUSED
#define WSAECONNREFUSED ECONNREFUSED
#endif
#ifndef WSAETIMEDOUT
#define WSAETIMEDOUT    ETIMEDOUT
#endif
#ifndef WSAENOTCONN
#define WSAENOTCONN     ENOTCONN
#endif
#ifndef WSAECONNRESET
#define WSAECONNRESET   ECONNRESET
#endif
#ifndef WSAEISCONN
#define WSAEISCONN      EISCONN
#endif
#ifndef WSAEALREADY
#define WSAEALREADY     EALREADY
#endif
#ifndef WSAEADDRINUSE
#define WSAEADDRINUSE   EADDRINUSE
#endif

// Remaining Winsock error codes -> POSIX errno equivalents. These are
// referenced by DEBUG_LOG/DEBUG_ASSERTCRASH diagnostics in the networking
// code (udp.cpp, GameSpy threads); they only need to exist to compile, and
// mapping to the matching BSD errno gives the closest behavioural match.
#ifndef WSABASEERR
#define WSABASEERR      10000
#endif
#ifndef WSAEINTR
#define WSAEINTR        EINTR
#endif
#ifndef WSAEBADF
#define WSAEBADF        EBADF
#endif
#ifndef WSAEACCES
#define WSAEACCES       EACCES
#endif
#ifndef WSAEFAULT
#define WSAEFAULT       EFAULT
#endif
#ifndef WSAEMFILE
#define WSAEMFILE       EMFILE
#endif
#ifndef WSAEMSGSIZE
#define WSAEMSGSIZE     EMSGSIZE
#endif
#ifndef WSAEPROTOTYPE
#define WSAEPROTOTYPE   EPROTOTYPE
#endif
#ifndef WSAENOPROTOOPT
#define WSAENOPROTOOPT  ENOPROTOOPT
#endif
#ifndef WSAEPROTONOSUPPORT
#define WSAEPROTONOSUPPORT EPROTONOSUPPORT
#endif
#ifndef WSAESOCKTNOSUPPORT
#define WSAESOCKTNOSUPPORT ESOCKTNOSUPPORT
#endif
#ifndef WSAEOPNOTSUPP
#define WSAEOPNOTSUPP   EOPNOTSUPP
#endif
#ifndef WSAEPFNOSUPPORT
#define WSAEPFNOSUPPORT EPFNOSUPPORT
#endif
#ifndef WSAEAFNOSUPPORT
#define WSAEAFNOSUPPORT EAFNOSUPPORT
#endif
#ifndef WSAEADDRNOTAVAIL
#define WSAEADDRNOTAVAIL EADDRNOTAVAIL
#endif
#ifndef WSAENETDOWN
#define WSAENETDOWN     ENETDOWN
#endif
#ifndef WSAENETUNREACH
#define WSAENETUNREACH  ENETUNREACH
#endif
#ifndef WSAENETRESET
#define WSAENETRESET    ENETRESET
#endif
#ifndef WSAECONNABORTED
#define WSAECONNABORTED ECONNABORTED
#endif
#ifndef WSAENOBUFS
#define WSAENOBUFS      ENOBUFS
#endif
#ifndef WSAEDESTADDRREQ
#define WSAEDESTADDRREQ EDESTADDRREQ
#endif
#ifndef WSAENOTSOCK
#define WSAENOTSOCK     ENOTSOCK
#endif
#ifndef WSAESHUTDOWN
#define WSAESHUTDOWN    ESHUTDOWN
#endif
#ifndef WSAETOOMANYREFS
#define WSAETOOMANYREFS ETOOMANYREFS
#endif
#ifndef WSAEHOSTDOWN
#define WSAEHOSTDOWN    EHOSTDOWN
#endif
#ifndef WSAEHOSTUNREACH
#define WSAEHOSTUNREACH EHOSTUNREACH
#endif
#ifndef WSAELOOP
#define WSAELOOP        ELOOP
#endif
#ifndef WSAENAMETOOLONG
#define WSAENAMETOOLONG ENAMETOOLONG
#endif
#ifndef WSAENOTEMPTY
#define WSAENOTEMPTY    ENOTEMPTY
#endif
#ifndef WSAEUSERS
#define WSAEUSERS       EUSERS
#endif
#ifndef WSAEDQUOT
#define WSAEDQUOT       EDQUOT
#endif
#ifndef WSAESTALE
#define WSAESTALE       ESTALE
#endif
#ifndef WSAEREMOTE
#define WSAEREMOTE      EREMOTE
#endif
#ifndef WSAEPROCLIM
#define WSAEPROCLIM     EPROCLIM
#endif
// No POSIX equivalent for "graceful shutdown in progress"; use the Win32 value.
#ifndef WSAEDISCON
#define WSAEDISCON      (WSABASEERR + 101)
#endif

// Winsock startup / name-resolution error codes. No POSIX errno equivalents;
// these only appear in diagnostic switch/case logging, so we use the canonical
// Win32 numeric values purely so the code compiles.
#ifndef WSASYSNOTREADY
#define WSASYSNOTREADY      (WSABASEERR + 91)
#endif
#ifndef WSAVERNOTSUPPORTED
#define WSAVERNOTSUPPORTED  (WSABASEERR + 92)
#endif
#ifndef WSANOTINITIALISED
#define WSANOTINITIALISED   (WSABASEERR + 93)
#endif
#ifndef WSAHOST_NOT_FOUND
#define WSAHOST_NOT_FOUND   (WSABASEERR + 1001)
#endif
#ifndef WSATRY_AGAIN
#define WSATRY_AGAIN        (WSABASEERR + 1002)
#endif
#ifndef WSANO_RECOVERY
#define WSANO_RECOVERY      (WSABASEERR + 1003)
#endif
#ifndef WSANO_DATA
#define WSANO_DATA          (WSABASEERR + 1004)
#endif

// HOSTENT is the Win32 alias for `struct hostent` (from <netdb.h>).
typedef struct hostent HOSTENT, *LPHOSTENT;
typedef struct sockaddr_in SOCKADDR_IN, *LPSOCKADDR_IN;
typedef struct sockaddr SOCKADDR, *LPSOCKADDR;
inline int ioctlsocket(SOCKET s, long cmd, unsigned long* argp) {
    // Only the non-blocking toggle is used by the engine.
    int flags = ::fcntl(s, F_GETFL, 0);
    if (argp && *argp) ::fcntl(s, F_SETFL, flags | O_NONBLOCK);
    else               ::fcntl(s, F_SETFL, flags & ~O_NONBLOCK);
    return 0;
}

// ---------------------------------------------------------------------------
// socklen_t-vs-int signature shims.
//
// The Win32 sockets API takes `int*` for the address-length out-parameters of
// getsockname/getpeername/accept/recvfrom and the `int*` optlen of getsockopt.
// BSD sockets take `socklen_t*` (unsigned int on macOS). The engine consistently
// passes `int*`, so we add C++ overloads that accept `int*`, bounce through a
// socklen_t temporary, and forward to the real BSD calls. Because socklen_t
// (unsigned int) differs from `int`, these overloads do not collide with the
// libc declarations.
// TODO(macos): networking is compile-only for now (multiplayer not wired up).
// ---------------------------------------------------------------------------
inline int getsockname(SOCKET s, struct sockaddr* addr, int* namelen) {
    socklen_t len = namelen ? (socklen_t)*namelen : 0;
    int r = ::getsockname(s, addr, &len);
    if (namelen) *namelen = (int)len;
    return r;
}
inline int getpeername(SOCKET s, struct sockaddr* addr, int* namelen) {
    socklen_t len = namelen ? (socklen_t)*namelen : 0;
    int r = ::getpeername(s, addr, &len);
    if (namelen) *namelen = (int)len;
    return r;
}
inline int recvfrom(SOCKET s, char* buf, int len, int flags,
                    struct sockaddr* from, int* fromlen) {
    socklen_t fl = fromlen ? (socklen_t)*fromlen : 0;
    int r = (int)::recvfrom(s, buf, (size_t)len, flags, from, fromlen ? &fl : nullptr);
    if (fromlen) *fromlen = (int)fl;
    return r;
}
inline int getsockopt(SOCKET s, int level, int optname, void* optval, int* optlen) {
    socklen_t ol = optlen ? (socklen_t)*optlen : 0;
    int r = ::getsockopt(s, level, optname, optval, optlen ? &ol : nullptr);
    if (optlen) *optlen = (int)ol;
    return r;
}
#endif // !_WIN32
