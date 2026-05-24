# GeneralsGameCode-macOS

**Native Metal port of Command & Conquer: Generals Zero Hour for Apple Silicon.**

This is a personal, experimental fork. It does **not** use Wine, DXVK,
MoltenVK, CrossOver, or any other translation layer — the engine compiles
as a native macOS binary that talks to Apple's Metal API through a custom
in-tree D3D8 → Metal shim.

> This project is unrelated to any mods or remakes with similar names.
> It does not change gameplay, balance, AI, scripts, or game data.
> It only changes the **platform layer** so the existing game runs on macOS.

## Status

In active development. The game boots, loads, and runs a stable 1v1
skirmish on Apple Silicon (verified on M3 Max). Rendering correctness
covers the LOW graphics preset; Medium / High introduce additional
features (volumetric shadows, reflective water, heat distortion, MSAA)
that are still being ported.

For the full session-by-session technical history — every bug, root
cause, and fix — see [`MACOS_PORT_PLAN.md`](MACOS_PORT_PLAN.md).

## Relation to other community projects

This fork is **complementary, not competing**. There are at least three
parallel community efforts to keep Generals alive, each making different
tradeoffs:

| Project | Approach | Platform target |
|---|---|---|
| [**TheSuperHackers/GeneralsGameCode**](https://github.com/TheSuperHackers/GeneralsGameCode) | Upstream — stability, bug fixes, retail compatibility, gradual modernization | Windows (primary); cross-platform aspirations |
| [**fbraz3/GeneralsX**](https://github.com/fbraz3/GeneralsX) | DXVK (D3D8→Vulkan) + SDL3 + OpenAL + FFmpeg | Linux + macOS via single cross-platform codebase |
| [**Fighter19/CnC_Generals_Zero_Hour**](https://github.com/Fighter19/CnC_Generals_Zero_Hour) | Original Linux port that pioneered DXVK / SDL3 / OpenAL groundwork | Linux-focused reference |
| **This fork (`GeneralsGameCode-macOS`)** | Native D3D8→Metal shim, Cocoa input, **no Vulkan / no translation layer** | macOS ARM64 only |

The goal here is to explore how lean a macOS-native port can be when
the engine talks directly to Metal — no translation tax, no Vulkan
intermediate, no Wine. It's an experiment in minimum-overhead porting,
not a replacement for either upstream or the Linux+macOS cross-platform
work that GeneralsX is doing.

If your priority is **stability + Windows + community contributions** →
use TheSuperHackers. If your priority is **Linux + macOS through a
proven Vulkan stack** → use GeneralsX. This fork is for the curious /
the experimenter who wants to see Metal driven directly.

## Architecture

```
+--------------------------------------------------+
|  Original Generals / Zero Hour C++ engine        |
|  (unmodified game logic, AI, scripts, INI)       |
+--------------------------------------------------+
|  WW3D2 + Win32 API surface (unchanged interface) |
+--------------------------------------------------+
|  osdep_compat/  — Win32 -> POSIX/Cocoa shim      |  <-- new
|  cmake/dx8_stub/ — D3D8 -> Metal shim            |  <-- new
|  Cocoa input + AppKit window backend             |  <-- new
+--------------------------------------------------+
|  macOS / Metal / Cocoa                           |
+--------------------------------------------------+
```

Engine code is kept as close to upstream as practical. macOS-specific
tweaks live inside `#if defined(__APPLE__)` guards so the upstream
Windows MSVC build keeps compiling.

## Build

```bash
# Configure (Ninja Multi-Config, apple-arm64 preset)
cmake --preset apple-arm64

# Build Release
cmake --build build/apple-arm64 --config Release --target generalszh
```

Output: `build/apple-arm64/GeneralsMD/Release/generalszh`

## Run

The binary needs the original Generals: Zero Hour data files. **You must
own a legitimate copy** — those proprietary EA assets are NOT and will
NOT be in this repository. Place the executable next to your install:

```bash
ABIN=$(pwd)/build/apple-arm64/GeneralsMD/Release/generalszh
cd "/path/to/Command and Conquer Generals Zero Hour"
"$ABIN"
```

### Debug entry points

| Env var | Effect |
|---|---|
| `GEN_AUTO_SKIRMISH=1` | Boot straight into a 1v1 skirmish (skip menus) |
| `GEN_MODEL_VIEWER=1 GEN_MODEL=<name>` | Isolated W3D model viewer (e.g. `AIRngr_SKN`) |
| `GEN_MODEL_ANIM=<htree>.<anim>` | Drive an animation in the viewer |
| `GEN_QUICK_MENU=1` | Skip intro, land on main menu fast |
| `GEN_GFX_PRESET=low\|medium\|high\|veryhigh` | Force a static-LOD preset |
| `GEN_FORCE_SHADOW_VOL=0/1` etc. | Override individual graphics flags one at a time |
| `MTL_DUMP=1` | Capture per-frame PNGs to `/tmp/gen_frame_*.png` |
| `MTL_DEBUG=1` | Per-frame draw-call stats to stderr |
| `MTL_TEXONLY=1` | Fragment shader returns raw texture sample (skip combiner+lighting) |

See [`MACOS_PORT_PLAN.md`](MACOS_PORT_PLAN.md) for the full env-var
inventory and what each was added to bisect.

## Contributions

This is an **experimental personal fork**. Pull requests are not
currently being accepted — the direction is intentionally exploratory
and I'm driving it myself.

**Bug reports for the macOS path are welcome** as
[GitHub Issues](https://github.com/dvcdsys/GeneralsGameCode-macOS/issues).
Please include:
- macOS version + chip (M1 / M2 / M3 / M4)
- Reproducer (steps + which env vars set)
- Screenshot or short capture

For anything that affects the **shared engine code** (not macOS-specific),
please file upstream at
[TheSuperHackers/GeneralsGameCode](https://github.com/TheSuperHackers/GeneralsGameCode/issues)
instead — those fixes benefit everyone.

## Upstream sync

This fork tracks
[TheSuperHackers/GeneralsGameCode](https://github.com/TheSuperHackers/GeneralsGameCode)
as the `upstream` remote.

```bash
git fetch upstream
git merge upstream/main   # or rebase, depending on workflow
```

macOS-specific changes are concentrated in:
- `cmake/dx8_stub/*` — the D3D8→Metal shim
- `Dependencies/Utility/osdep_compat/*` — Win32 compat headers
- `Core/.../Win32Device/.../CocoaKeyboard.{h,cpp}` — Cocoa input
- Sparse `#if defined(__APPLE__)` blocks in engine sources

so merge conflicts with upstream should be rare and surgical.

## License & legal

Inherited from upstream: **GPL-3.0-or-later**, with the EA additional
terms. See [`LICENSE.md`](LICENSE.md) for the full text.

EA has not endorsed and does not support this product. All trademarks
are the property of their respective owners.

## Credits

- **Westwood Studios** for the original *Command & Conquer: Generals*
- **EA** for releasing the engine source under GPL-3
- **[TheSuperHackers](https://github.com/TheSuperHackers/GeneralsGameCode)** for the modernized C++ baseline this fork builds on
- **[fbraz3 (GeneralsX)](https://github.com/fbraz3/GeneralsX)** for the parallel Linux+macOS effort — their cross-platform packaging and docs structure inspired some of this README

---

For upstream's project description (community Discord, multi-platform
roadmap, contribution flow, etc.) see [`README_UPSTREAM.md`](README_UPSTREAM.md).
