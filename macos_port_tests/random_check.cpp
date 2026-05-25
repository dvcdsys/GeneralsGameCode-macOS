// macos_port_tests/random_check.cpp
//
// Determinism test for WWLib's RandomClass (the LCG used by gameplay).
// This is a STATELESS test: given seed S, the sequence rand()...rand()
// must produce identical 32-bit words on macOS arm64 LP64 and Win32 x86.
//
// On a healthy build:
//   Seed=12345 → first 16 outputs match the golden Win32 reference list
//
// On a broken (raw `unsigned long Seed`) build:
//   Seed math operates in 64-bit, so (Seed*K + C) does NOT wrap at 2^32
//   and the sequence diverges by the first or second call.
//
// Golden values were captured by hand-simulating the LCG with 32-bit
// arithmetic, which is what Win32 `unsigned long` (4 bytes) gives.
// Formula (verbatim from RandomClass::operator()):
//   Seed = (Seed * 0x41C64E6D) + 0x00003039        // mod 2^32 on Win32
//   return (Seed >> 10) & 0x7FFF                    // 15-bit return
//
// We compute the golden table here in 32-bit math, then compare to what
// the linked RandomClass actually returns. If they match, sim RNG is
// deterministic vs retail.

#include <cstdio>
#include <cstdint>
#include <cstdlib>

#include "Utility/CppMacros.h"
#include "PreRTS.h"

#include "RANDOM.h"

// Compute the "golden" sequence by hand in pure uint32_t.
static uint16_t golden_next(uint32_t& seed)
{
    seed = (seed * 0x41C64E6Du) + 0x00003039u;   // mod 2^32 implicit on uint32_t
    return static_cast<uint16_t>((seed >> 10) & 0x7FFFu);
}

int main()
{
    constexpr uint32_t kSeed = 12345u;
    constexpr int      kN    = 32;

    // --- pure uint32_t reference ---
    uint32_t goldSeed = kSeed;
    uint16_t gold[kN];
    for (int i = 0; i < kN; ++i)
        gold[i] = golden_next(goldSeed);

    // --- engine RandomClass ---
    RandomClass rng(kSeed);
    uint16_t got[kN];
    for (int i = 0; i < kN; ++i)
        got[i] = static_cast<uint16_t>(rng());

    // --- compare ---
    int mismatches = 0;
    std::printf("=== RandomClass LCG determinism check ===\n");
    std::printf("seed=%u, sizeof(Seed) was 4 bytes on Win32; we want same here.\n\n", kSeed);
    std::printf("  i    expected   got        match\n");
    for (int i = 0; i < kN; ++i) {
        const bool ok = (gold[i] == got[i]);
        std::printf("  %2d   %5u      %5u      %s\n", i, gold[i], got[i], ok ? "OK" : "MISMATCH");
        if (!ok) ++mismatches;
    }

    std::printf("\nMismatches: %d / %d\n", mismatches, kN);
    if (mismatches != 0) {
        std::printf("FAIL — RandomClass diverges from 32-bit LCG. Sim is non-deterministic vs Win32.\n");
        return 1;
    }
    std::printf("PASS — RandomClass produces identical sequence to 32-bit LCG.\n");
    return 0;
}
