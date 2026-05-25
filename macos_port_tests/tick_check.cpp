// macos_port_tests/tick_check.cpp
//
// Phase 1 (current): boots only the memory manager. Verifies that the
// bare-minimum engine bootstrap chain compiles + links + runs to
// initMemoryManager() + shutdownMemoryManager().
//
// Phase 2 (planned): add ThingFactory, ArmorStore, WeaponStore,
// ModuleFactory, GameLogic, PlayerList, TeamFactory. Programmatically
// build one ThingTemplate (with ActiveBody + SlowDeathBehavior), make
// two Objects out of it, fire attemptDamage() at one, tick GameLogic
// for N frames, verify the Object ends up in the destroy list and
// is gone.
//
// Why incremental: every engine subsystem has heavy hidden deps. We
// surface them at link time, add the next library/source as the error
// demands, and keep moving.

#include <cstdio>

#include "Utility/CppMacros.h"
#include "PreRTS.h"

#include "Common/GameMemory.h"

// Stubs for app-level globals that the engine library expects from
// WinMain.cpp. We provide minimal definitions so the linker is happy.
HWND ApplicationHWnd = nullptr;
const char *g_strFile = "data\\Generals.str";
const char *g_csfFile = "data\\%s\\Generals.csf";
const char *gAppPrefix = "tick_test_";

int main()
{
    std::printf("tick_check: phase 1 — memory manager bootstrap\n");

    initMemoryManager();
    std::printf("  initMemoryManager OK\n");

    shutdownMemoryManager();
    std::printf("  shutdownMemoryManager OK\n");

    std::printf("PASS — phase 1 bootstrap.\n");
    return 0;
}
