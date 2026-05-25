# macos_port_tests — Isolated C++ harnesses for sim-state debugging

Standalone test programs that exercise specific engine subsystems
**without launching the full game**. Iteration loop target: **<1 second
build + run**.

## Why

Restarting the full game to validate a fix is a 30-second turnaround,
and reads "did it work?" off pixel-rendered HUDs. That's the worst
kind of feedback loop. Instead, write a tiny harness for the slice of
code you suspect, run it in milliseconds, get deterministic PASS/FAIL.

The harnesses are not unit tests in the JUnit sense — they're
**diagnostic probes**: each one isolates one suspect mechanism (LP64
struct layout, RNG determinism, damage→death, sleepy-update scheduler,
…) and emits a report we can diff against the Win32 reference.

## Existing harnesses

| Harness          | Question it answers                                                  | Build/run |
|------------------|----------------------------------------------------------------------|-----------|
| `sizeof_check`   | Are basic engine types the right size on LP64? (DWORD=4, ULONG=4, …) | `bash run_sizeof.sh` |
| `random_check`   | Does `RandomClass`'s LCG match the 32-bit Win32 reference sequence?  | `bash run_random.sh` |
| `tick_check`     | Phase 1 — does the engine library link + the memory manager boot?     | `bash run_tick.sh`   |

## How to add one

1. Copy `run_sizeof.sh` to `run_<topic>.sh` — it harvests the same
   compile flags the engine uses for ActiveBody.cpp.
2. Write `<topic>_check.cpp`. Top of file:
   ```cpp
   #include "Utility/CppMacros.h"   // CPP_11() etc. usually from PCH
   #include "PreRTS.h"              // engine canonical pre-include
   ```
3. If your harness exercises engine .cpp code (not just headers), add
   the source file paths to the `${CC}` invocation in your script and
   pass `-include CppMacros.h` so the per-TU build sees the macros.
4. Verify: `bash run_<topic>.sh` should build + report in under 2s.

## Findings so far

- **sizeof_check** — PASS. DWORD/ULONG/LONG = 4 bytes, AsciiString/UnicodeString = 8 bytes.
  No basic-typedef LP64 hazards.
- **random_check** — PASS after fixing `RandomClass::Seed` from
  `unsigned long` (8 bytes on macOS) to `uint32_t`. Before fix:
  multiplication did not wrap at 2^32, sequence diverged on call #1.

## Reserved future harnesses

- `tick_check` — drive `GameLogic::update()` for N frames against a
  bootstrapped minimal world. Validates damage→`onDie`→`destroyObject`→
  `processDestroyList` actually executes.
- `lp64_field_scan` — automated header scan for raw `(unsigned) long`
  member declarations (catches LP64 landmines that the DWORD typedef
  sweep doesn't reach).
- `crc_check` — feed known bytes into `CRCEngine`, compare against the
  Win32 reference CRC.
