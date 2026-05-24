#pragma once

// Unix / macOS portability shim.
//
// The original Westwood "osdep.h" that the WWVegas libraries include on the
// _UNIX path was never committed to this repository. The Win32 -> POSIX
// substitutions it used to provide now live in Dependencies/Utility/Utility/*
// (compat.h and friends). This forwarding header lets the many
// `#include "osdep.h"` sites across WWMath / WW3D2 / WWSaveLoad resolve on
// non-Windows targets without scattering platform #ifdefs through them.

#include "Utility/compat.h"
