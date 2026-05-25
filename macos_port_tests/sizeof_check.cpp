// macos_port_tests/sizeof_check.cpp
//
// Standalone harness: reports sizeof() + offsetof() of types that are
// critical for ABI compatibility with the original 2004 Win32 build.
// Win32 ABI: long = 4 bytes; LP64 (macOS arm64): long = 8 bytes.
//
// We compile this with the SAME flags as ActiveBody.cpp so we get
// identical typedefs and packing. No bootstrap, no singletons, no
// linking against the engine library. Pure header sizeof.
//
// Build via macos_port_tests/run_sizeof.sh (harvests flags from
// compile_commands.json).
//
// Expected sizes (Win32 reference):
//   DWORD                = 4
//   ULONG                = 4
//   HANDLE               = pointer (4 on Win32 x86, 8 on macOS arm64 — OK, opaque)
//   Real                 = 4
//   ObjectID             = 4 (used as DWORD index)
//   DrawableID           = 4
//   PartitionID          = (depends on engine)
//
// Any failure to compile / static_assert here means we still have
// LP64 landmines that explain "units don't die, AI frozen, struct
// state corrupt" symptoms.

#include <cstdio>
#include <cstddef>
#include <cstdint>

// Engine .cpp files get CppMacros.h via the precompiled header. We don't
// use a PCH, so include it explicitly so CPP_11() etc. resolve in Errors.h.
#include "Utility/CppMacros.h"

// Pull in the engine's canonical pre-include. PreRTS.h drags in
// windows.h (our osdep_compat shim on macOS), atlbase.h, BaseType.h,
// AsciiString.h, ... — i.e. everything every engine .cpp sees.
// This is the most-honest possible sizeof harness: identical macro
// and typedef state as the real translation units.
#include "PreRTS.h"

// Game structs whose layout matters for sim/save/network state.
#include "Common/Team.h"
#include "Common/Player.h"
#include "GameLogic/Object.h"
#include "GameLogic/Module/BodyModule.h"
#include "GameLogic/Module/ActiveBody.h"
#include "GameLogic/Damage.h"
#include "GameLogic/AIPlayer.h"
#include "GameLogic/AIPathfind.h"

// Win32 reference: these must be exactly 4 bytes for binary state
// compatibility with retail save files and network protocols.
static_assert(sizeof(DWORD)  == 4, "DWORD must be 32-bit (Win32 ABI)");
static_assert(sizeof(ULONG)  == 4, "ULONG must be 32-bit (Win32 ABI)");
static_assert(sizeof(WORD)   == 2, "WORD must be 16-bit");
static_assert(sizeof(BYTE)   == 1, "BYTE must be 8-bit");
static_assert(sizeof(Bool)   == 1, "Bool must be 1 byte");
static_assert(sizeof(Real)   == 4, "Real must be float32");
static_assert(sizeof(Int)    == 4, "Int must be 32-bit");
static_assert(sizeof(UnsignedInt) == 4, "UnsignedInt must be 32-bit");

#define PRINT_SIZE(T) std::printf("  %-40s = %zu bytes\n", #T, sizeof(T))

int main()
{
    std::printf("=== macOS LP64 Type Layout Report ===\n");
    std::printf("Compiled %s %s\n\n", __DATE__, __TIME__);

    std::printf("Pointer-sized:\n");
    PRINT_SIZE(void*);
    PRINT_SIZE(size_t);
    PRINT_SIZE(intptr_t);

    std::printf("\nBasic Win32 typedefs (engine):\n");
    PRINT_SIZE(BYTE);
    PRINT_SIZE(WORD);
    PRINT_SIZE(DWORD);
    PRINT_SIZE(ULONG);
    PRINT_SIZE(LONG);
    PRINT_SIZE(Bool);

    std::printf("\nEngine numeric types:\n");
    PRINT_SIZE(Int);
    PRINT_SIZE(UnsignedInt);
    PRINT_SIZE(Real);
    PRINT_SIZE(Int64);
    PRINT_SIZE(UnsignedInt64);

    std::printf("\nC++ stdint sanity:\n");
    PRINT_SIZE(uint32_t);
    PRINT_SIZE(int32_t);
    PRINT_SIZE(uint64_t);
    PRINT_SIZE(long);          // <-- LP64 hazard: 8 on macOS, 4 on Win32
    PRINT_SIZE(unsigned long); // <-- same

    std::printf("\nC++ class:\n");
    PRINT_SIZE(AsciiString);
    PRINT_SIZE(UnicodeString);

    std::printf("\nGame core (size = total layout):\n");
    PRINT_SIZE(Object);
    PRINT_SIZE(BodyModule);
    PRINT_SIZE(ActiveBody);
    PRINT_SIZE(DamageInfo);
    PRINT_SIZE(DamageInfoInput);
    PRINT_SIZE(DamageInfoOutput);
    PRINT_SIZE(AIPlayer);
    PRINT_SIZE(Player);
    PRINT_SIZE(Team);

    std::printf("\nPathfinder (bit-fielded — ABI hazard):\n");
    PRINT_SIZE(PathfindCell);
    PRINT_SIZE(PathfindCellInfo);
    PRINT_SIZE(PathfindLayer);
    PRINT_SIZE(zoneStorageType);
    // Retail x86 Win32 reference size for PathfindCell is 32 bytes — bit
    // packing puts m_info(4) + m_obstacleID(4) + bitfield_word_1(4) +
    // bitfield_word_2(2 with padding) + ... aligned to 32. If macOS Clang
    // produces a different size, the hierarchical pathfinder may walk past
    // valid cells or read stale neighbour links.
    static_assert(sizeof(zoneStorageType) == 2, "zoneStorageType must be 16-bit");

    std::printf("\n=== ALL static_asserts PASSED ===\n");
    return 0;
}
