#pragma once

// ---------------------------------------------------------------------------
// POSIX-backed shim for the small slice of the Win32 *registry* API used by
// the engine (WWDownload/registry.cpp). It is a real, file-backed key/value
// store so per-user game settings actually persist across runs.
//
// Layout: each registry key maps to one file rooted at
//   ~/Library/Application Support/CommandAndConquerGenerals/registry/
// The Win32 key path (e.g. "SOFTWARE\Electronic Arts\...\Options") is turned
// into a relative file path by replacing '\\' and '/' with '_' and prefixing
// the root hive name (HKCU / HKLM). Each line in the file is "name=value".
// Only REG_SZ and REG_DWORD value types are exercised by the engine; values
// are stored as text (DWORDs as decimal) and re-typed on read.
//
// Header-only / inline so no extra .cpp or CMake wiring is needed.
// ---------------------------------------------------------------------------

#ifndef _WIN32

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>

// ---------------------------------------------------------------------------
// Registry constants / types.
// ---------------------------------------------------------------------------
#ifndef ERROR_SUCCESS
#define ERROR_SUCCESS        0L
#endif
#ifndef ERROR_FILE_NOT_FOUND
#define ERROR_FILE_NOT_FOUND 2L
#endif
#ifndef ERROR_MORE_DATA
#define ERROR_MORE_DATA      234L
#endif

#ifndef REG_NONE
#define REG_NONE   0
#endif
#ifndef REG_SZ
#define REG_SZ     1
#endif
#ifndef REG_BINARY
#define REG_BINARY 3
#endif
#ifndef REG_DWORD
#define REG_DWORD  4
#endif

// Access rights (ignored by this shim, but must exist as constants).
#ifndef KEY_QUERY_VALUE
#define KEY_QUERY_VALUE        0x0001
#endif
#ifndef KEY_SET_VALUE
#define KEY_SET_VALUE          0x0002
#endif
#ifndef KEY_READ
#define KEY_READ               0x20019
#endif
#ifndef KEY_WRITE
#define KEY_WRITE              0x20006
#endif
#ifndef KEY_ALL_ACCESS
#define KEY_ALL_ACCESS         0xF003F
#endif

// Creation options (ignored).
#ifndef REG_OPTION_NON_VOLATILE
#define REG_OPTION_NON_VOLATILE 0x00000000L
#endif
#ifndef REG_OPTION_VOLATILE
#define REG_OPTION_VOLATILE     0x00000001L
#endif

// Disposition returned by RegCreateKeyEx.
#ifndef REG_CREATED_NEW_KEY
#define REG_CREATED_NEW_KEY     0x00000001L
#endif
#ifndef REG_OPENED_EXISTING_KEY
#define REG_OPENED_EXISTING_KEY 0x00000002L
#endif

// REGSAM is a DWORD-typed access mask on Win32.
typedef DWORD REGSAM;

// Predefined hive handles. Real Win32 uses sentinel pointer values; we mirror
// that with two distinct, non-NULL constants the shim can recognize.
#ifndef HKEY_CLASSES_ROOT
#define HKEY_CLASSES_ROOT   ((HKEY)(uintptr_t)0x80000000ull)
#define HKEY_CURRENT_USER   ((HKEY)(uintptr_t)0x80000001ull)
#define HKEY_LOCAL_MACHINE  ((HKEY)(uintptr_t)0x80000002ull)
#define HKEY_USERS          ((HKEY)(uintptr_t)0x80000003ull)
#endif

namespace osdep_compat_detail {

// An opened registry key: the absolute on-disk file backing it.
struct RegKey
{
  std::string file;   // absolute path to the backing key file
};

inline std::string reg_root_dir()
{
  const char *home = ::getenv("HOME");
  std::string base = home ? home : ".";
  base += "/Library/Application Support/CommandAndConquerGenerals/registry";
  return base;
}

inline bool reg_is_predefined(HKEY h)
{
  uintptr_t v = (uintptr_t)h;
  return v >= 0x80000000ull && v <= 0x800000FFull;
}

inline const char *reg_hive_name(HKEY h)
{
  if (h == HKEY_CURRENT_USER)  return "HKCU";
  if (h == HKEY_LOCAL_MACHINE) return "HKLM";
  if (h == HKEY_CLASSES_ROOT)  return "HKCR";
  if (h == HKEY_USERS)         return "HKU";
  return "HKEY";
}

// Sanitize a Win32 key path into a single flat filename component.
inline std::string reg_sanitize(const char *path)
{
  std::string out;
  for (const char *p = path; p && *p; ++p) {
    char c = *p;
    if (c == '\\' || c == '/' || c == ':') c = '_';
    out += c;
  }
  return out;
}

// Build the absolute backing-file path for (hive, subkey).
inline std::string reg_key_file(HKEY hive, const char *subkey)
{
  std::string f = reg_root_dir();
  f += '/';
  f += reg_hive_name(hive);
  f += '_';
  f += reg_sanitize(subkey ? subkey : "");
  f += ".reg";
  return f;
}

// mkdir -p for the registry root.
inline void reg_ensure_root()
{
  std::string dir = reg_root_dir();
  std::string acc;
  for (size_t i = 0; i < dir.size(); ++i) {
    acc += dir[i];
    if (dir[i] == '/' && acc.size() > 1)
      ::mkdir(acc.c_str(), 0755);
  }
  ::mkdir(dir.c_str(), 0755);
}

// Read the value for `name` from a key file. Returns true if found, filling
// `value` (raw text after '=') and `type` (REG_DWORD if all-digits, else REG_SZ).
inline bool reg_read_value(const std::string &file, const char *name,
                           std::string &value, DWORD &type)
{
  FILE *fp = ::fopen(file.c_str(), "rb");
  if (!fp) return false;
  char line[1024];
  bool found = false;
  size_t nameLen = name ? ::strlen(name) : 0;
  while (::fgets(line, sizeof(line), fp)) {
    // strip trailing newline(s)
    size_t len = ::strlen(line);
    while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = 0;
    char *eq = ::strchr(line, '=');
    if (!eq) continue;
    *eq = 0;
    if (nameLen == 0 ? (line[0] == 0) : (::strcmp(line, name) == 0)) {
      value = eq + 1;
      // Heuristic: detect type prefix written by reg_write_value.
      if (value.rfind("dword:", 0) == 0) { type = REG_DWORD; value.erase(0, 6); }
      else if (value.rfind("sz:", 0) == 0) { type = REG_SZ; value.erase(0, 3); }
      else { type = REG_SZ; }
      found = true;
      break;
    }
  }
  ::fclose(fp);
  return found;
}

// Insert/replace the value for `name` in a key file (creating it if needed).
inline bool reg_write_value(const std::string &file, const char *name,
                            DWORD type, const std::string &value)
{
  reg_ensure_root();

  // Read existing lines, replacing the matching name.
  std::string out;
  bool replaced = false;
  size_t nameLen = name ? ::strlen(name) : 0;
  std::string typedValue = (type == REG_DWORD ? "dword:" : "sz:") + value;

  FILE *in = ::fopen(file.c_str(), "rb");
  if (in) {
    char line[1024];
    while (::fgets(line, sizeof(line), in)) {
      size_t len = ::strlen(line);
      std::string raw(line, len);
      while (!raw.empty() && (raw.back() == '\n' || raw.back() == '\r')) raw.pop_back();
      size_t eq = raw.find('=');
      std::string key = (eq == std::string::npos) ? raw : raw.substr(0, eq);
      if (nameLen == 0 ? key.empty() : (key == name)) {
        out += std::string(name ? name : "") + "=" + typedValue + "\n";
        replaced = true;
      } else if (!raw.empty()) {
        out += raw + "\n";
      }
    }
    ::fclose(in);
  }
  if (!replaced)
    out += std::string(name ? name : "") + "=" + typedValue + "\n";

  FILE *o = ::fopen(file.c_str(), "wb");
  if (!o) return false;
  ::fwrite(out.data(), 1, out.size(), o);
  ::fclose(o);
  return true;
}

} // namespace osdep_compat_detail

// ---------------------------------------------------------------------------
// Win32 registry API surface (ANSI). Signatures match the Windows SDK so the
// engine call sites compile unchanged. The W/A unsuffixed names are what the
// engine uses, so we define those directly.
// ---------------------------------------------------------------------------

inline LONG RegOpenKeyEx(HKEY hKey, LPCSTR subKey, DWORD /*options*/,
                         REGSAM /*sam*/, PHKEY result)
{
  using namespace osdep_compat_detail;
  if (!result) return ERROR_FILE_NOT_FOUND;
  if (!reg_is_predefined(hKey)) return ERROR_FILE_NOT_FOUND;

  std::string file = reg_key_file(hKey, subKey);
  FILE *fp = ::fopen(file.c_str(), "rb");
  if (!fp) return ERROR_FILE_NOT_FOUND;
  ::fclose(fp);

  RegKey *rk = new RegKey();
  rk->file = file;
  *result = (HKEY)rk;
  return ERROR_SUCCESS;
}

inline LONG RegCreateKeyEx(HKEY hKey, LPCSTR subKey, DWORD /*reserved*/,
                           LPSTR /*classStr*/, DWORD /*options*/, REGSAM /*sam*/,
                           void * /*securityAttrs*/, PHKEY result,
                           PDWORD disposition)
{
  using namespace osdep_compat_detail;
  if (!result) return ERROR_FILE_NOT_FOUND;
  if (!reg_is_predefined(hKey)) return ERROR_FILE_NOT_FOUND;

  reg_ensure_root();
  std::string file = reg_key_file(hKey, subKey);

  bool existed = false;
  FILE *fp = ::fopen(file.c_str(), "rb");
  if (fp) { existed = true; ::fclose(fp); }
  else {
    // Touch the file so the key "exists".
    fp = ::fopen(file.c_str(), "ab");
    if (!fp) return ERROR_FILE_NOT_FOUND;
    ::fclose(fp);
  }

  RegKey *rk = new RegKey();
  rk->file = file;
  *result = (HKEY)rk;
  if (disposition)
    *disposition = existed ? REG_OPENED_EXISTING_KEY : REG_CREATED_NEW_KEY;
  return ERROR_SUCCESS;
}

inline LONG RegQueryValueEx(HKEY hKey, LPCSTR valueName, PDWORD /*reserved*/,
                            PDWORD type, LPBYTE data, PDWORD dataSize)
{
  using namespace osdep_compat_detail;
  if (reg_is_predefined(hKey) || hKey == nullptr) return ERROR_FILE_NOT_FOUND;
  RegKey *rk = (RegKey *)hKey;

  std::string value;
  DWORD valType = REG_SZ;
  if (!reg_read_value(rk->file, valueName, value, valType))
    return ERROR_FILE_NOT_FOUND;

  if (type) *type = valType;

  if (valType == REG_DWORD) {
    DWORD v = (DWORD)::strtoul(value.c_str(), nullptr, 10);
    if (data) {
      if (!dataSize || *dataSize < sizeof(DWORD)) {
        if (dataSize) *dataSize = sizeof(DWORD);
        return ERROR_MORE_DATA;
      }
      ::memcpy(data, &v, sizeof(DWORD));
    }
    if (dataSize) *dataSize = sizeof(DWORD);
    return ERROR_SUCCESS;
  }

  // REG_SZ (and anything else): copy string + NUL.
  DWORD needed = (DWORD)value.size() + 1;
  if (data) {
    if (!dataSize || *dataSize < needed) {
      if (dataSize) *dataSize = needed;
      return ERROR_MORE_DATA;
    }
    ::memcpy(data, value.c_str(), needed);
  }
  if (dataSize) *dataSize = needed;
  return ERROR_SUCCESS;
}

inline LONG RegSetValueEx(HKEY hKey, LPCSTR valueName, DWORD /*reserved*/,
                          DWORD type, const BYTE *data, DWORD dataSize)
{
  using namespace osdep_compat_detail;
  if (reg_is_predefined(hKey) || hKey == nullptr) return ERROR_FILE_NOT_FOUND;
  RegKey *rk = (RegKey *)hKey;

  std::string value;
  if (type == REG_DWORD) {
    DWORD v = 0;
    if (data) ::memcpy(&v, data, sizeof(DWORD) <= dataSize ? sizeof(DWORD) : dataSize);
    char buf[32];
    ::snprintf(buf, sizeof(buf), "%lu", (unsigned long)v);
    value = buf;
  } else {
    // REG_SZ / other: treat as text, honoring dataSize (drop trailing NUL).
    if (data && dataSize) {
      DWORD len = dataSize;
      if (len > 0 && data[len-1] == 0) --len;
      value.assign((const char *)data, len);
    }
  }

  return reg_write_value(rk->file, valueName, type, value) ? ERROR_SUCCESS
                                                           : ERROR_FILE_NOT_FOUND;
}

inline LONG RegCloseKey(HKEY hKey)
{
  using namespace osdep_compat_detail;
  if (reg_is_predefined(hKey) || hKey == nullptr) return ERROR_SUCCESS;
  delete (RegKey *)hKey;
  return ERROR_SUCCESS;
}

#endif // !_WIN32
