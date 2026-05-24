// macOS stub for WWLib RegistryClass.
//
// The real implementation (Core/.../WWLib/registry.cpp) wraps the Win32
// registry API and is only compiled on WIN32 (see WWLib/CMakeLists.txt). The
// engine still references RegistryClass on macOS (W3DDisplay, dx8wrapper,
// WWAudio) to read/write user settings. Until a native settings backend is
// wired up, provide stubs that report an invalid key and return defaults, so
// the engine reads fall back to their default values and writes are no-ops.

#include "registry.h"
#include <cstring>

RegistryClass::RegistryClass(const char* /*sub_key*/, bool /*create*/)
    : Key(0), IsValid(false)
{
    // No native registry yet: mark invalid so callers use defaults.
}

RegistryClass::~RegistryClass()
{
}

int RegistryClass::Get_Int(const char* /*name*/, int def_value)
{
    return def_value;
}

void RegistryClass::Set_Int(const char* /*name*/, int /*value*/)
{
}

char* RegistryClass::Get_String(const char* /*name*/, char* value, int value_size,
                                const char* default_string)
{
    if (value && value_size > 0)
    {
        if (default_string)
        {
            std::strncpy(value, default_string, value_size - 1);
            value[value_size - 1] = '\0';
        }
        else
        {
            value[0] = '\0';
        }
    }
    return value;
}

void RegistryClass::Set_String(const char* /*name*/, const char* /*value*/)
{
}
