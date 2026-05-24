# Command & Conquer: Generals Zero Hour — macOS Native Port

This is a macOS-native ARM64 (Apple Silicon) port of
[TheSuperHackers/GeneralsGameCode](https://github.com/TheSuperHackers/GeneralsGameCode).
It does **not** use Wine, DXVK, MoltenVK, CrossOver, or any translation
layer: the engine compiles as a native macOS binary that talks to Apple's
Metal API through a custom in-tree D3D8 → Metal shim.

## Status

In active development. The game boots, loads, and runs a stable 1v1
skirmish on Apple Silicon (verified on M3 Max). Rendering correctness
covers the LOW graphics preset; Medium / High introduce additional
features (volumetric shadows, reflective water, heat distortion, MSAA)
that are still being ported.

For the full session-by-session technical history — every bug, root cause,
and fix — see [`MACOS_PORT_PLAN.md`](MACOS_PORT_PLAN.md).

## Architecture

```
+--------------------------------------------------+
|  Original Generals / Zero Hour C++ engine        |
|  (unmodified game logic, AI, scripts, INI)       |
+--------------------------------------------------+
|  WW3D2 + Win32 API surface (unchanged interface) |
+--------------------------------------------------+
|  osdep_compat/  — Win32 → POSIX/Cocoa shim       |  <-- new
|  cmake/dx8_stub/ — D3D8 → Metal shim             |  <-- new
|  Cocoa input + AppKit window backend             |  <-- new
+--------------------------------------------------+
|  macOS / Metal / Cocoa                           |
+--------------------------------------------------+
```

Engine code is kept as close to upstream as practical. macOS-specific
tweaks live inside `#if defined(__APPLE__)` guards so the upstream
Windows MSVC build stays compilable.

## Build

```bash
# Configure (Ninja Multi-Config, apple-arm64 preset)
cmake --preset apple-arm64

# Build Release
cmake --build build/apple-arm64 --config Release --target generalszh
```

Output: `build/apple-arm64/GeneralsMD/Release/generalszh`

## Run

The binary needs the original Generals: Zero Hour data files. You must
own a legitimate copy — those assets are NOT and will NOT be in this
repository. Drop the executable next to your install:

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

## Constraints / non-goals

- **No proprietary EA assets in this repository.** The `original/`
  directory (where you put your installed game) is `.gitignore`d.
- macOS-specific code is guarded with `#if defined(__APPLE__)`; the
  Windows build path remains intact.
- The shim translates D3D8 → Metal — it does NOT add modern features
  the engine doesn't already know about. Shader-based effects that
  the engine relies on (e.g. heat distortion HLSL, water reflection
  render-to-texture) need parallel MSL implementations; see the plan.
- License: **GPL-3.0-or-later**, inherited from upstream.

## Upstream sync

This fork tracks
[TheSuperHackers/GeneralsGameCode](https://github.com/TheSuperHackers/GeneralsGameCode)
as the `upstream` remote. To pull improvements:

```bash
git fetch upstream
git merge upstream/main   # or rebase, depending on workflow
```

Most macOS-specific changes are in:
- `cmake/dx8_stub/*` — the shim (your additions)
- `Dependencies/Utility/osdep_compat/*` — Win32 compat headers
- `Core/.../Win32Device/.../CocoaKeyboard.{h,cpp}` — Cocoa input
- Sparse `#if defined(__APPLE__)` blocks in engine sources

so merge conflicts with upstream should be rare and surgical.
