# GeneralsGameCode — Native macOS (Apple Silicon) Port Plan

> **Goal:** Command & Conquer Generals: **Zero Hour** running **fully playable, natively** on this Apple Silicon MacBook (arm64) — main menu, skirmish, campaign, with graphics + input + audio. No Wine, no Rosetta.
>
> **How to use this document:** Each numbered **Stage** below is designed to be a *separate working session*. Open a new session, point the agent at this file, and say e.g. *"Do Stage 1 from MACOS_PORT_PLAN.md"*. Every stage section is self-contained: goal, prerequisites, key files, step-by-step approach, how to verify, pitfalls, and a clear "Done when…".
>
> **Branch:** `macos-port-phase1`. All work is local & uncommitted unless the user explicitly asks to commit.

> ### 🔒 SHIM-ONLY RULE (effective 2026-05-24)
>
> **All new rendering / graphics work goes EXCLUSIVELY into `cmake/dx8_stub/`.**
> No edits to game engine code (`GeneralsMD/Code/`, `Generals/Code/`,
> `Core/GameEngine*/`), even guarded with `#if defined(__APPLE__)`.
>
> Features that *seem* to need engine cooperation (shadow mapping →
> scene-from-light render, water reflection → RT setup, etc.) must be
> implemented by the shim **observing D3D8 state + capturing/replaying
> draw calls** — not by hooking the engine. The engine must remain a
> clean Windows/DX8 codebase; the macOS port lives entirely in the
> translation layer.
>
> *Single narrow exception:* `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.{cpp,h}`
> straddles engine/shim. Tiny `__APPLE__` patches there are tolerated
> only for **cap-query / `Has_*()` overrides**; no new draw-time logic.
>
> *Grandfathered (pre-2026-05-24, don't extend):* engine edits in
> `Drawable.cpp`, `HeightMap.cpp`, `WorldHeightMap.cpp`,
> `W3DModelDraw.cpp`, `W3DDisplay.cpp` (model-viewer + drawFillRect
> clamp + `GEN_AUTO_SKIRMISH`), `render2dsentence.cpp` font clamp,
> `GameEngine.cpp` `GEN_FORCE_*` harness. Don't add new ones.

> ### 🛰️ Shim-only shadow mapping (infrastructure ✅, not yet wired to UI)
>
> Original Generals uses **stencil shadow volumes** (`W3DVolumetricShadow`)
> and **projected blob decals** (`W3DProjectedShadowManager`). Neither is
> shadow mapping. **DXVK and MoltenVK do not implement shadow mapping
> either** — they're API translators (D3D9→Vulkan, Vulkan→Metal). So our
> shadow map is a *new technique* layered on top of the shim, with no
> upstream precedent.
>
> What we DID borrow from those projects:
> - **Hardware slope-scale depth bias** via Metal's
>   `[MTLRenderCommandEncoder setDepthBias:slopeScale:clamp:]` (MoltenVK's
>   implementation of `vkCmdSetDepthBias`). Replaces a constant NDC bias
>   in the fragment shader — slope-scale automatically gives steep-slope
>   receivers (ship hulls, vehicle silhouettes) more bias and flat
>   receivers (ground, deck) less, eliminating peter-panning. Tuned for
>   Generals: `slope=2.5`, `const=1.0`, `clamp=0` (env-overridable via
>   `MTL_SHADOW_SLOPE_BIAS` / `MTL_SHADOW_CONST_BIAS`).
> - **Tight light far range** (4000u, was 12000u, env
>   `MTL_SHADOW_FAR_RANGE`): bias is depth-buffer-LSB at far plane, so a
>   shorter range scales the absolute world-space offset down 3×.
>
> Technique: capture+replay. Every opaque XYZ colour-writing draw in the
> main pass has its VB/IB retained into `shadowCaptures`; at Present time
> we re-emit those draws against a 4096² Depth32Float texture using the
> sun's view+ortho. Next frame's main fragment shader samples that map
> with 3×3 PCF. 1-frame latency, 2× geometry GPU. Engine code untouched.
> Currently env-gated (`MTL_SHADOW=1`); engine UI hookup is planned as
> part of the **Advanced Display Options sweep** below — most likely
> hijacking the "3D Shadows" checkbox (whose original stencil-volume code
> path is a dead end on macOS anyway).

> ### 🪥 Shim-only MSAA (infrastructure ✅, not yet wired to UI)
>
> Original D3D8 `D3DMULTISAMPLE_*` is enumerated by
> `WW3D::getRenderDevice()->isMultiSampleSupported()` but never wired into
> the Metal pipeline — before this shim infrastructure landed, the colour
> drawable and depth texture were both `sampleCount=1` so the render
> output was crawling with stair edges (ship masts, helicopter rotors,
> building roof slopes, cliffs).
>
> Implementation (shim only, `cmake/dx8_stub/metal_backend.mm`):
> - **MSAA colour** texture: `textureType2DMultisample`, BGRA8Unorm,
>   `MTLStorageModeMemoryless` — lives entirely in TBDR tile memory.
>   Render pass uses `colorAttachments[0].resolveTexture =
>   drawable.texture` with `storeAction = MultisampleResolve`, so the
>   resolved pixels land in the CAMetalLayer drawable, and we never pay
>   the off-tile bandwidth.
> - **MSAA depth** texture: `Depth32Float_Stencil8`,
>   `textureType2DMultisample` matching sampleCount, also memoryless
>   (storeAction=DontCare — we never resolve depth; main pass is the
>   only consumer).
> - All main-pass `MTLRenderPipelineDescriptor` get
>   `pd.rasterSampleCount = msaaSamples`; shadow pipelines (which render
>   into the plain Depth32Float 4096² shadowMap) stay
>   `rasterSampleCount = 1`. Pipeline cache key didn't need a new
>   dimension because `msaaSamples` is captured once at
>   `MetalContext_Create`.
> - Env: `MTL_MSAA=0|1|2|4|8`, default **4**. Unsupported counts
>   (e.g. 8x on M3 for BGRA8Unorm) auto-fall-back to 1 via
>   `[device supportsTextureSampleCount:]` with a `[metal] MSAA xN not
>   supported, falling back to off` log line.
>
> What we did NOT borrow / why DXVK/MoltenVK weren't useful here:
> MoltenVK only implements multisample for Vulkan render passes that
> already specify `rasterizationSamples`; DXVK delegates D3D9 MSAA to
> Vulkan natively. Neither has logic to **add** MSAA to a single-sample
> pipeline against the wishes of the source API, which is exactly what
> the shim does (the engine still passes through D3D8's "no MSAA"
> default). So this is a shim-only feature, gated only by env var.
>
> Cost on M-series TBDR: ≈0% perf, 0 bytes off-tile (tile-memory
> resolve). Verified clean rendering at 4x across shellmap (ships,
> palms, cliffs, helicopters) and skirmish (cliffs, trees, buildings),
> with shadows (`MTL_SHADOW=1`) working unchanged alongside MSAA.
> Currently env-gated (`MTL_MSAA=N`); engine UI hookup planned as part of
> the **Advanced Display Options sweep** below (driven by the standalone
> AA combo `m_antiAliasLevel`, not from the 10 checkboxes).

---

## ▶ Current focus: Advanced Display Options sweep (2026-05-24 →)

The macOS port is **playable end-to-end** through Stages 0–4 (boot →
shellmap → skirmish → playable). The next chunk of work is **not new
features** — it's making each of the **10 checkboxes** in
`Options → Custom → Advanced Display Options` actually behave on macOS.

Today, most of those checkboxes either no-op or visibly artefact when
ticked, because their engine code paths assume a full D3D8 pipeline
(stencil volumes, second-stage TSS sampling, framebuffer-readback post
effects) that the Metal shim doesn't yet emulate. The shim-only shadow
map + MSAA infrastructure already built (docs above) are *plumbing* that
the right checkboxes will hook into.

**Engine-side rule:** the engine UI is untouched — no rename, no preset
swap, no new option. The `Options → Detail` dropdown stays
`Low / Medium / High / Very High / Custom` as in retail. Users test by
**picking `Custom`** → opening Advanced Display Options → ticking the
checkbox they want.

**Methodology — one checkbox at a time:**

1. Pick the next ⬜ row in the sweep table below.
2. User ticks the checkbox in `Options → Custom → Advanced Display Options`
   → starts a skirmish → captures frame dump / screenshot / log of the
   artefact (or "feature simply doesn't fire").
3. Trace from the engine-side `m_*` field through the W3D path that
   reads it (W3DScene, W3DProjectedShadowManager, W3DWater, etc.) into
   the D3D8 calls the shim sees.
4. Fix at SHIM level (`cmake/dx8_stub/`). Engine touches only when
   truly unavoidable, under `#if defined(__APPLE__)` (see SHIM-ONLY rule).
5. Verify the checkbox now produces visually correct output across
   shellmap + skirmish + at least one campaign mission, with **no
   regressions** when the checkbox is OFF and no regressions on other
   already-fixed checkboxes.
6. Tick the row, log root cause + fix file paths in the "completed work"
   sub-section under this header, move to the next row.

**Stop conditions for "fixed":**
- Visually matches Windows reference (or our best approximation when the
  feature is partially broken on Windows too — e.g. heat effects on
  some Intel cards).
- No artefacts (z-fight, black tiles, flicker, double-shadowing).
- Toggle is symmetric (OFF after ON returns to identical pre-toggle frame).
- Works in shellmap *and* skirmish (catches submission-order bugs).

**Test-run discipline (mandatory between every screenshot run):**
- Always launch headless game runs as `(... & PID=$!; sleep N; kill -9 $PID; wait)`.
- `pkill -9 -f generalszh` + verify with `pgrep -f generalszh` returns empty
  *before* and *after* each run — leftover zombies append PNG dumps to
  `/tmp/gen_frame_*.png` and corrupt the A/B comparison of the next run.
- **Move** `/tmp/gen_frame_*.png` into the per-run subdir *between* runs,
  so dumps from the previous config don't get mistaken for the current.
- See `/tmp/test_3d_shadows.sh` for the canonical pattern.

**Debug-first iteration rule (added 2026-05-25, user-mandated):**
When a shim-only fix fails to land cleanly because we can't *see* what
the engine is doing, **temporary engine edits ARE allowed for debugging
purposes**, with the following contract:

1. **Isolate the broken subsystem.** Don't debug inside the full
   shellmap intro / live skirmish if a smaller harness can repro the
   bug. Build a minimal launch mode (debug env-gated bypass of menu /
   one-object scene / fixed camera / fixed light) that exercises ONLY
   the broken feature. The existing `GEN_MODEL_VIEWER`, `GEN_AUTO_SKIRMISH`,
   `MTL_SHADOW_VIZ` envs are precedent — add more in the same style.
2. **Engine-side visualization is fair game.** Patching
   `W3DVolumetricShadowManager` to render an RGB ramp keyed off the
   stencil value (instead of darken pass), or dumping stencil/depth to
   a debug texture, or printing per-object volume counts — all OK if
   gated by an env var the user can flip off.
3. **All engine edits MUST be reverted before declaring the fix done.**
   Final `git diff` must show **only** `cmake/dx8_stub/` (and
   `MACOS_PORT_PLAN.md`) modified. The shim fix itself stays. The
   engine instrumentation goes. If the engine edit is so useful it
   "should" stay (e.g. a permanently-useful diagnostic), surface it as
   a separate proposal — don't sneak it in.
4. **No "debug edit just for this PR" smuggling.** The git-diff check
   at the end is what users see; engine edits don't belong there.
   Verified by running `git diff --stat -- 'GeneralsMD/Code/*' 'Generals/Code/*' 'Core/GameEngine*/*'`
   → must be empty before completion.
5. **Why this rule:** with shim-only debugging we were guessing at
   what the engine emits and what the GPU actually does with it. The
   Z-Pass→Z-Fail rewrite "looked right" by diff-stat but visually
   regressed skirmish — because we never *visualised* the stencil
   buffer to confirm the rewrite produced sensible per-pixel counts.
   Engine-side viz would have caught that in minutes.

Workflow for a flaky shim fix:
```
diagnose → engine-viz hook (gated) → isolated launch script → screenshot →
read pixels → root-cause → shim fix → screenshot confirms → revert engine →
final git-diff check → done
```

**DXMT reference project (added 2026-05-25, user-mandated):**
A working D3D9/10/11 → Metal translation layer is cloned and
cix-indexed locally at `/Users/dvcdsys/Cursor/dxmt`. When you do
not know how to implement a Metal-side feature correctly, **consult
DXMT first** before guessing.

How to query it: `cd /Users/dvcdsys/Cursor/dxmt && cix search "..."`
(its own cix index is separate from the GeneralsGameCode index).
Useful entry-points to read:
- `src/dxmt/dxmt_sampler.{hpp,cpp}` — sampler-state mapping
- `src/d3d11/d3d11_state_object.cpp` — D3D11_SAMPLER_DESC →
  `WMTSamplerInfo`, depth-stencil descriptors, blend descriptors
- `src/dxmt/dxmt_texture.{hpp,cpp}` — texture creation, BC/DXT
  pixel-format mapping, MSAA/sampleCount, view caching
- `src/dxmt/dxmt_shader_cache.{hpp,cpp}` — persistent on-disk PSO
  binary archive (we don't need persistence yet, but the in-memory
  hash-keyed PSO cache pattern is the same)
- `src/d3d11/d3d11_pipeline.{hpp,cpp}` — render-pipeline-state
  caching keyed off shader+layout+attachments
- `src/airconv/` — DXBC → AIR / MSL shader transpiler; for our
  FF emulation we don't transpile DXBC (Generals uses fixed
  function, not SM2+ shaders), but the MSL emission patterns
  are reusable

What DXMT does NOT solve for us:
- D3D8 surface (DXMT enters at D3D9 minimum) — we still need the
  shim's D3D8 device / surface / state-block machinery
- Fixed Function combiner emulation — DXMT assumes DXBC input;
  Generals submits no shaders, only D3DRS_/D3DTSS_ state → we
  must synthesise MSL FF shaders ourselves
- Engine-level LP64 traps (struct stride / DWORD) — orthogonal
  to anything DXMT does

Rule of thumb: when a shim subsystem (sampler, depth/stencil,
PSO cache, texture upload, MSAA) feels under-specified or you
catch yourself guessing field semantics, **read DXMT's
implementation of the same subsystem before writing code**.
This is the cheap-and-fast path; trial-and-error against the
Generals engine costs us hours of A/B captures.

### Sweep table

| # | UI Checkbox            | Engine field                     | Native D3D8 behaviour                                                                                          | Shim status | Strategy notes |
|---|------------------------|----------------------------------|----------------------------------------------------------------------------------------------------------------|-------------|----------------|
| 1 | 3D Shadows             | `m_useShadowVolumes`             | `W3DVolumetricShadow` stencil shadow volumes: extrude silhouette, ±stencil, darken pixels in shadow            | ✅ working   | Three-fix landing (caps + XYZRHW + stencil-ref mask); Z-Fail rewrite tried, reverted to opt-in. See "Sweep — completed work" below. |
| 2 | 2D Shadows             | `m_useShadowDecals`              | `W3DProjectedShadowManager` projected blob decals (texture-projected dark disc under each unit)                | ✅ working   | LP64 fix: `SHADOW_DECAL_VERTEX::diffuse` forced to `uint32_t` under `__APPLE__` (DWORD was 8 bytes → stride 32 vs 24 → black rectangles). See "Sweep — completed work". |
| 3 | Cloud Shadows          | `m_useCloudMap`                  | Terrain second-stage TSS sampler scrolling a cloud noise texture with a D3DTS_TEXTURE1 UV transform            | ⬜ artefacts | Multi-texture stage-1 path not plumbed in shim FF MSL. Same shape as the Stage-4 cliff-shroud TCI fix, but at TSS stage 1 instead of stage 0. |
| 4 | Extra Ground Lighting  | `m_useLightMap`                  | Same second-stage path as #3, different sampler texture (TSNoise*)                                             | ⬜ artefacts | Shares the stage-1 plumbing with #3 — fix one, the other is essentially free. |
| 5 | Smooth Water Borders   | `m_showSoftWaterEdge`            | Extra shoreline geometry with alpha-feather; engine calls `TheTerrainVisual->setShoreLineDetail()`             | ⬜ artefacts | Touches the water path which already needed an Apple-only skip (shroud-pass2 in Stage 4). Investigate the alpha-feather geometry submission. |
| 6 | Behind Buildings       | `m_enableBehindBuildingMarkers`  | "See through enemy buildings": stencil-based occlusion mark + a post-occlusion shader pass                     | ⬜ artefacts | Same stencil prerequisite as #1. Partially unblocked by the Stage-4 ZENABLE stencil seed, but the actual stencil-shadow draw paths are untested. |
| 7 | Show Props             | `m_useTrees`                     | Trees rendered at all                                                                                          | ✅ working   | — |
| 8 | Extra Animations       | `!m_useDrawModuleLOD`            | Construction scaffolds + secondary animation modules (cranes mid-buildup)                                      | ⬛ untested  | Likely working (pure W3D anim path, same machinery as built models). Just needs verification + a screenshot. |
| 9 | Disable Dynamic LOD    | `!m_enableDynamicLOD`            | Don't auto-degrade particle/debris density when FPS drops                                                      | ✅ working (CPU only) | — |
| 10| Heat Effects           | `m_useHeatEffects`               | Full-screen distortion ripple (Microwave Tank, fire): offscreen RT + UV-perturb sample                         | ⬜ artefacts | Requires render-to-texture infrastructure (not yet built) + a pixel-shader equivalent. Most expensive — leave for last. |

**Legend:** ✅ working · 🔶 partial · ⬜ artefacts/broken · ⬛ untested

**Suggested order** (easy → hard, grouping shared infra):
- **Cheap verifications first** (7, 8, 9) — confirm what already works.
- **Multi-texture family** (3, 4) — fix once, two checkboxes light up.
- **Shadow family** (1, 2) — hook up the existing shadow-mapping infra;
  decide blob-decal coexistence.
- **Water** (5) — independent, moderate complexity.
- **Stencil-dependent** (6) — needs more stencil pipeline work first.
- **Heat Effects** (10) — last; requires brand-new RT + PS infrastructure.

### Sweep — completed work

#### #2 — 2D Shadows — LP64 DWORD stride trap in SHADOW_DECAL_VERTEX (2026-05-25)

**Symptom:** with `m_useShadowDecals=TRUE` (Options → Custom → 2D Shadows
ticked, or `GEN_FORCE_SHADOW_DECAL=1`), every caster painted a **solid
opaque black RECTANGLE** under its position instead of the soft brown
blob shadow the texture asset describes. The whole quad → pure black
multiplied terrain → very obvious artefact.

**Discovery (debug-first methodology):**
1. 4-config A/B (`nothing` / `decals_only` / `volumes_only` / `both`) on
   shellmap proved the artefact was the **decal pass only** and not a
   double-darken interaction with 3D shadows.
2. Shim diagnostic `MTL_DECAL_LOG=1` (gated, harmless when off) dumped
   per-`FVF=0x142` draw state — initially noisy because tree billboards
   share the FVF.
3. Per "Debug-first iteration rule": temporarily edited
   `W3DProjectedShadowManager::flushDecals` to call weak shim hooks
   `MetalDebug_DecalPass_Begin/End` that flipped a flag. Shim diagnostic
   now logged ONLY actual decal-pass draws. **The engine edit and the
   matching shim symbols are reverted at end of task** — `git diff`
   against engine paths shows only the narrow LP64 fix.
4. With the marker filter in place, the log showed all real decal draws
   with `stride=32 diffOff=12 uvOff=16 diff0=0x00000000 uv0=(nan,nan)`.
   But the engine struct is:
   ```cpp
   struct SHADOW_DECAL_VERTEX { float x,y,z; DWORD diffuse; float u,v; };
   ```
   On Win32 `sizeof = 12+4+8 = 24`. On macOS LP64 with
   `typedef unsigned long DWORD` (per `bittype.h` / `osdep_compat/windows.h`)
   `DWORD = 8 bytes` + struct padding → `sizeof = 32`. The shim's
   `SetStreamSource` stride faithfully reported `sizeof(struct) = 32`,
   the FF combiner walked vertices at +32, every diffuse field past the
   first read padding/garbage (mostly 0) → fragment colour
   = `texture × 0x00000000 = pure black`.

**Root cause:** classical LP64 trap, same playbook as `bittype.h`
`uint32 = unsigned int` (W3D mesh loader), `ddsfile.h` `void* → unsigned`
(DDS texture loader), `TGA2Footer` 32-bit fields. `DWORD` *means* a
32-bit field; `unsigned long` on macOS LP64 makes it 64-bit.

**Fix (engine, narrow `__APPLE__`-only):** `W3DProjectedShadow.cpp`
`SHADOW_DECAL_VERTEX::diffuse` → `uint32_t` under `__APPLE__`. 16 lines,
no-op on Windows (where `uint32_t == DWORD == 4 bytes`).

Why not global DWORD typedef change: tried it in
`Dependencies/Utility/osdep_compat/windows.h` and
`Core/.../WWLib/bittype.h`. The change broke API call sites
(`RegQueryValueEx(..., &type, ..., &size)`, `CreateThread(..., &threadid)`,
`ValidateDevice(&passes)`) where callers declared the OUT parameter as
`unsigned long` to match the historical DWORD width — the fix would
have cascaded into many engine touch-points outside SHIM scope.
Per-struct narrow fix is the safer scoped solution; latent LP64 issues
in other DWORD-bearing structs are queued for the same playbook when
they surface.

**Verified:**
- `/tmp/2dshadow_decals_only/gen_frame_0900.png` — beach units now have
  soft brown blob shadows under them; the previous solid-black
  rectangles are gone.
- `/tmp/2dshadow_both/gen_frame_0900.png` — 2D + 3D shadows coexist
  cleanly (no double-darken artefact).
- `/tmp/2dshadow_volumes_only/gen_frame_0900.png` — unchanged
  (volumes-only path independent of this fix).
- Per-frame pixel diff `decals_only` vs `nothing` jumps from
  zero-meaningful (rectangles WERE on screen but solid black) to
  0.1–0.35 mean RGB localised under units — proper blob contribution.
- Engine `git diff --stat` shows only `W3DProjectedShadow.cpp` +16
  lines, all under `__APPLE__`.

**Status:** ✅ done — 2D Shadows checkbox now produces correct blob
decals. Engine touch is one narrow LP64-fix block, matching the
existing playbook for this class of macOS port issue.

**Files changed:**
- `GeneralsMD/Code/.../Shadow/W3DProjectedShadow.cpp` — `SHADOW_DECAL_VERTEX::diffuse`
  → `uint32_t` (Apple-only).
- `cmake/dx8_stub/metal_backend.mm` — kept the `MTL_DECAL_LOG` /
  `MTL_DECAL_WHITETEX` diagnostic envs (off by default, useful for
  future LP64 hunts).

---

#### #1 — 3D Shadows — stencil-volume geometry leak fixed (2026-05-24)

**Symptom (before fix):** with `m_useShadowVolumes=TRUE` (Options → Custom →
3D Shadows ticked, or `GEN_FORCE_SHADOW_VOL=1`), the engine's shadow-volume
extrusion geometry leaked into the visible framebuffer as large dark
trapezoidal patches — wherever a unit/building would have cast a stencil
shadow, the *volume mesh itself* rendered into colour instead of being
written to stencil only.

**Root cause:** the shim's `GetDeviceCaps` (`cmake/dx8_stub/dx8_device.cpp`)
did NOT advertise `D3DPMISCCAPS_COLORWRITEENABLE`. `W3DVolumetricShadow::renderShadows`
(GeneralsMD line 3483) probes this cap to choose between two stencil-fill
paths:
- **Happy path** (cap present) → `D3DRS_COLORWRITEENABLE=0`, geometry writes
  stencil only, no colour.
- **Fake path** (cap absent) → emulates colour-suppression via
  `D3DRS_ALPHABLENDENABLE=TRUE` + `SRCBLEND=ZERO` + `DESTBLEND=ONE`.
  This *should* leave dest unchanged but didn't on the shim, presumably
  because the no-vertex-colour shadow volume geometry interacted with
  blend state in a way that still wrote dark pixels.

Without the cap, engine took the fake path → volume geometry visible.

**Fix (1 line, SHIM only):** `cmake/dx8_stub/dx8_device.cpp` —
`pCaps->PrimitiveMiscCaps |= D3DPMISCCAPS_COLORWRITEENABLE`. The shim's
`GetPipeline` already mapped `dc->colorWriteMask == 0` to
`MTLColorWriteMaskNone` (since Stage 5 stencil work), so once the engine
started actually writing `D3DRS_COLORWRITEENABLE=0`, the volume mesh
stopped leaking. Zero engine touches.

**Verified:** `/tmp/test_3d_shadows.sh` 4-config bench (baseline /
volumes / noStencil / ourShadow) on shellmap intro. After fix: `volumes`
frame 0900 is pixel-identical to `baseline` — no dark trapezoid
artefacts. Before fix: `volumes` had a large dark trapezoid across the
centre of the scene.

**Follow-up fix (same session): XYZRHW pre-transformed quad rendering**

The first cap fix removed the visible volume-geometry leak but the actual
shadow darkening still wasn't appearing. Root cause #2:
`W3DVolumetricShadowManager::renderStencilShadows` (line 3340) draws a
full-screen quad with `D3DFVF_XYZRHW | D3DFVF_DIFFUSE` — pre-transformed
pixel-space coords with the engine relying on the driver to detect the
`XYZRHW` FVF flag and skip world/view/projection. Our shim's `vs_main`
was unconditionally applying `u.mvp * pos`, so the 4 quad vertices
(written at `(xpos+W, ypos+H, 0, 1)` etc.) got multiplied by whatever
3D MVP was last set → quad landed somewhere off-screen → no darkening.

**Fix (shim only, `cmake/dx8_stub/metal_backend.mm`):** add an XYZRHW
branch at the top of `vs_main` that applies the screen→NDC formula
matched to DXVK's `d3d9_fixed_function.cpp` pre-transform path
(`NDC = pos * invExtent + invOffset` followed by perspective divide).
For Metal NDC (Y-up) versus D3D screen (Y-down):
- `invExtent = (2/W, -2/H, 1, 1)`
- `invOffset = (-1, +1, 0, 0)`

Plumbed `viewportSize` (float2 pixel dims) into the Uniforms / UniformsCPU
structs (mirrored offsets, padded to keep `lights[]` alignment). Vertex
struct `VSIn.pos` widened to `float4` so the RHW component is readable;
Metal pads `.w=1.0` for the untransformed XYZ path (verified Apple Silicon).
Cleaned up the now-overlong `float4(in.pos, 1.0)` sites to
`float4(in.pos.xyz, 1.0)`.

**Verified:** skirmish frame `/tmp/3dshadows_skirm/baseline/gen_frame_3600.png`
shows real stencil shadow volumes — three trees in the scene cast
silhouette-shaped dark shadows on the ground, properly oriented. Before
the fix the same scene had no shadows at all. Other configs in the bench
(`volumes`, `ourShadow`) couldn't reproduce the side-by-side because the
auto-skirmish camera is nondeterministic across runs — but the
`baseline` capture is conclusive.

**Sources:** the screen→NDC formula came from
[DXVK d3d9_fixed_function.cpp](https://raw.githubusercontent.com/doitsujin/dxvk/master/src/d3d9/d3d9_fixed_function.cpp)
(`invExtent`/`invOffset` constants + perspective divide loop) and the
classic [GameDev.net XYZRHW emulation
thread](https://gamedev.net/forums/topic/376052-emulating-d3dfvf_xyzrhw/).

**Follow-up fix #3 (same session): stencil reference value 8-bit mask**

After fixes #1 (caps) and #2 (XYZRHW) shadows worked correctly in
skirmish, but on the shellmap intro the *entire screen* darkened: the
shadow-darken quad covered everything bright. Trace through the W3D
shadow code reveals engine sets `D3DRS_STENCILREF = 0x80808080` (a
"player-color isolator" sentinel for `flushOccludedObjectsIntoStencil`'s
multi-bit stencil packing). The shim was passing this raw uint32 to
Metal's `setStencilReferenceValue:` which then compared the **full
32-bit reference** against the 8-bit stencil sample
(Depth32Float_Stencil8). For shadow-quad's `D3DCMP_LESSEQUAL` test
(ref=0x80808080, mask=~0=0xFF effectively, stencil 8-bit), the compare
collapsed to "0x80808080 <= 0..255" → always true → quad always
darkened the pixel → uniform whole-screen darkening on any frame with
a renderStencilShadows pass. Skirmish was OK only because the AI camera
nondeterministic position happened to land on frames where the shadow
quad either failed for other reasons or fell outside the visible
viewport; shellmap intro has scripted camera + many shadow casters so
the bug fired every frame.

**Fix (1 line, SHIM only):** `cmake/dx8_stub/metal_backend.mm` —
`[ctx->enc setStencilReferenceValue:((uint32_t)dc->stencilRef & 0xFFu)]`.
Metal stencil refs are documented as 32-bit but only the low 8 bits
matter for 8-bit attachments; explicitly masking matches what real D3D8
drivers do under the hood. Also added an env-gated diagnostic
`MTL_STENCIL_LOG=1` that dumps per-draw stencil state for future
debugging of related issues.

**Verified:**
- `/tmp/shellmap_refmask/gen_frame_0360.png` — ship intro bright,
  no darkening (matches `GEN_NO_SHADOWS=1` baseline brightness).
- `/tmp/shellmap_refmask/gen_frame_0900.png` — beach scene with units +
  helicopters, normal colours.
- Skirmish (`/tmp/skirm_after/gen_frame_3600.png`) — construction yard
  scene renders cleanly, no regression.

**Follow-up #4 — Z-Pass → Z-Fail rewrite (TRIED AND REVERTED to opt-in)**

> Outcome: the rewrite **regressed** shadow rendering and was demoted
> to opt-in only (`MTL_SHADOW_ZFAIL=1`); default is the engine's native
> Z-Pass. Kept in the codebase as documentation + future hook. The
> three earlier fixes (caps + XYZRHW + stencil-ref mask) are
> sufficient on their own.

After fixes #1–#3 stencil volumes rendered, but on the shellmap intro
the volumes had **essentially zero visible effect** — pixel-diff of
`baseline` vs `GEN_NO_SHADOWS=1` was 0.9–1.9 mean RGB across every
frame, all of it animation jitter. The user's reference screenshot
shows long dark **streaks** across terrain coming from each unit — the
classic Z-Pass-volume failure mode.

Visualised by a debug toggle (`MTL_SHADOW_VOL_VIZ=1`, forces colour
writes on for stencil-write draws): every caster on the shellmap projects
a HUGE white tent-shaped volume mesh extruding along `-lightDir` and
covering large portions of the screen — and frequently extending off
the top edge or into the sky beyond the far plane.

**Root cause:** the engine emits the *Z-Pass* (depth-pass-counting)
form of stencil shadow volumes — `STENCILZFAIL=KEEP`,
`STENCILPASS=INCR/DECRSAT`, two passes with `CULLMODE` flipped between
`CW` and `CCW`. Z-Pass is fragile because it depends on **both** front
*and* back faces being rasterised on the same pixel — if the back face
is off-screen, behind the far plane, or occluded by other terrain
(`Z-Fail`, sent to `KEEP`), the INCR done by the front face never gets
cancelled. With the shellmap's very low sun
(`MorningLightPos = X:-0.96 Y:0.05 Z:-0.29` → near-horizontal
extrusion), volumes routinely extend hundreds of world units past the
visible frame → DECR pass touches almost nothing the INCR pass had →
stencil > 0 across wide swaths → darken pass paints "streaks".

Stencil-state log (`MTL_STENCIL_LOG=1`, cap raised to 100 000 lines/
frame so the DECR pass isn't hidden behind the INCR fill) confirmed:
`216642 INCR + 216642 DECRSAT + 659 darken` per scene — draw counts
balance, but visible-fragment counts don't.

**Fix (SHIM only, `cmake/dx8_stub/metal_backend.mm` `GetDepthState`):**
intercept the volume render state at the depth-stencil descriptor and
rewrite it to **Z-Fail (Carmack's Reverse)** before building the cache
entry. When the engine sends `sFail=KEEP, sZFail=KEEP, sPass∈{INCRSAT,
DECRSAT, INCR, DECR}` (the unique signature of the W3D Z-Pass volume
passes), we rewrite to:
- `sPass=KEEP` (no count on depth-pass)
- `sZFail = flipped(originalPass)` (count on depth-fail, opposite direction)
  - `INCRSAT ↔ DECRSAT`, `INCR ↔ DECR` (saturation choice preserved)

`CULLMODE` is left alone — the same face renders, only its stencil
action moves from `depthPass` to `depthFail` and the increment direction
inverts so the math still balances. The conversion is mathematically
equivalent to Z-Pass on a closed mesh **and** robust to camera-inside-
volume / off-screen / occluded back caps.

Gate: `MTL_SHADOW_ZPASS=1` reverts to legacy Z-Pass for A/B testing.
Default is Z-Fail.

**What we initially thought ("verified", before stencil viz):**
- `/tmp/shellmap_zfail/gen_frame_0900.png` vs
  `/tmp/shellmap_baseline/gen_frame_0900.png` — wide dark streaks
  apparently gone; units appeared to have localized silhouette shadows.
- Pixel-diff `zfail` vs `noShadows` jumped from 0.9–1.9 mean RGB to
  3.1–6.0 mean — volumes appeared to contribute meaningfully.
- Skirmish run showed a building with a clean shadow.

**What stencil viz actually showed (user reported regression first;
viz then proved it).** Engine instrumentation `MTL_STENCIL_VIZ=1`
(temporary edit to `W3DVolumetricShadowManager::renderStencilShadows`
gated by env) replaces the multiply-darken with a per-stencil-value
heatmap: green=1, yellow=2, orange=3, red=4, magenta=5, cyan=6,
blue=7, white=8+.

A/B captures (`/tmp/viz_shellmap_zfail_viz/gen_frame_0900.png`
vs `/tmp/viz_shellmap_zpass_viz/gen_frame_0900.png`):

- **Z-Pass (engine native)**: small green/yellow patches concentrated
  *under* casters — soldiers, helicopters, rocks. Distribution looks
  like real shadows from a low sun. **Correct**.
- **Z-Fail (our rewrite)**: large **white** (stencil ≥ 8) blobs
  smeared over mountains and water; small green patches anywhere
  else. Over-incremented by ~10× wherever a volume side-wall sweeps a
  region. **Wrong**.

**Why the rewrite over-increments:** Generals' shadow-volume meshes
are open extrusions (silhouette + extruded silhouette + side walls),
not closed cap-front + cap-back hulls. Z-Fail counts back-face
depth-fails as INCR — for an open mesh the long, sweeping side walls
have effectively unbalanced back-face Z-fail coverage, so the count
runs away in any region the volume sweeps but doesn't fully envelop.
Z-Pass is *correct for this engine* because the mesh shape is built
for the depth-pass-counting algorithm; INCR/DECR balance is preserved
by the on-screen front+back face pairs as long as both rasterise
(which the engine arranges by clipping the volume to the camera
frustum).

The earlier "diff jumped from 1.9 → 6.0 mean RGB" was real but for
the *wrong* reason — Z-Fail was overshooting, not finally activating
the shadow contribution.

**Resolution:** Z-Fail demoted to opt-in (`MTL_SHADOW_ZFAIL=1`),
default is engine-native Z-Pass (no rewrite, no `GetDepthState`
mutation). The engine-side viz code was reverted per the
"debug-first" rule (`git diff` against engine paths is empty at end).

**Status:** ✅ Z-Pass is correct out of the box once fixes #1–#3 are
in place. The user's perceived "streaks" turned out to be the
correct shadow rendering from the very low sun angle
(`MorningLightPos.Z = -0.29` → near-horizontal extrusion) — not a
bug, just an algorithmic consequence of the scene's lighting.

**Files changed (final, after Z-Fail revert):**
- `cmake/dx8_stub/dx8_device.cpp` — added `D3DPMISCCAPS_COLORWRITEENABLE`
- `cmake/dx8_stub/metal_backend.mm` — `VSIn.pos` float4, `Uniforms.viewportSize`,
  XYZRHW branch in `vs_main`, `UniformsCPU` mirror, viewport-size fill in
  the main-pass draw, **stencil ref masked to 8 bits**, optional Z-Fail
  rewrite in `GetDepthState` for shadow volumes (off by default, opt-in
  via `MTL_SHADOW_ZFAIL=1`), diagnostic envs (`MTL_STENCIL_LOG`,
  `MTL_SHADOW_VOL_VIZ`).
- Engine: **no diffs** — the temporary `MTL_STENCIL_VIZ` viz hook in
  `W3DVolumetricShadow.cpp::renderStencilShadows` was the experiment
  vehicle and is reverted; see "Debug-first iteration rule" above.

---

*(Add subsequent fixed checkboxes above, reverse-chronological.)*

---

## ▶ DWORD/ULONG LP64 typedef sweep (2026-05-25) — THE BIG ONE

**Context.** Engine was written for Win32 ABI: `unsigned long` = 4 bytes,
so the historical `typedef unsigned long DWORD` happened to be 32-bit
correct on Windows. On macOS LP64 `unsigned long` is **8 bytes**, so for
~22 years of the codebase **every** `DWORD` struct member, every
`sizeof(DWORD)` in offset/stride math, every `DWORD*` API call silently
got the wrong width. We had been fixing these one-by-one in playbook
(bittype.h `uint32`, ddsfile.h `void*→unsigned`, TGA2Footer, DataChunk
wchar_t, FVFInfoClass, D3DXGetFVFVertexSize, SHADOW_DECAL_VERTEX,
CRCEngine.h `long`, W3DShroud bounds). User correctly pointed out: fix
the root once.

**The fix (two typedefs):**
- `Core/Libraries/Source/WWVegas/WWLib/bittype.h`:
  `typedef unsigned long DWORD/ULONG` → `typedef uint32_t DWORD/ULONG`
  (gated `#if defined(__APPLE__)`; Win32 build untouched).
- `Dependencies/Utility/osdep_compat/windows.h`:
  same change — both files MUST stay in sync or C++ rejects the
  conflicting typedefs.

`LONG` had already been fixed to `int32_t` in a prior pass; `WORD` is
always 16-bit; we left `LONGLONG`/`DWORDLONG`/`QWORD` alone (they
correctly use 64-bit `int64_t`/`uint64_t`).

**Knock-on type fixes** — places that had locally declared `unsigned
long` variables to receive into Win32-ABI `LPDWORD` out-pointers (which
used to silently work when DWORD == unsigned long). All changed to
`DWORD`:
- `WWVegas/WWDownload/FTP.cpp` — CreateThread threadid
- `WWVegas/WW3D2/dx8wrapper.cpp` — D3DDevice->ValidateDevice passes
- `WWVegas/WWDownload/registry.cpp` — RegQueryValueEx size/type (both fns)
- `Core/GameEngine/Source/Common/System/registry.cpp` — same (both fns)
- `Core/GameEngine/Source/Common/System/StackDump.cpp` — pointer→DWORD
  cast now goes via `uintptr_t` (documented narrowing; macOS DbgHelp
  stub doesn't return meaningful frame symbols anyway)
- `Core/GameEngine/Source/GameClient/GUI/IMEManager.cpp` —
  ImmGetCandidateListCount listCount
- `Core/GameEngine/Source/GameNetwork/GameSpy/MainMenuUtils.cpp` —
  CreateThread threadid
- `Core/GameEngine/Source/GameNetwork/GameSpy/StagingRoomGameInfo.cpp`
  — SNMP function-pointer casts (DWORD parameter widths)
- `Core/GameEngine/Source/GameNetwork/GameSpy/Thread/PingThread.cpp` —
  ICMP function-pointer casts (DWORD timeouts/sizes)
- `Core/Libraries/Source/debug/debug_debug.cpp` — ReadFile io counters
- `Core/GameEngineDevice/Source/MilesAudioDevice/MilesAudioManager.cpp`
  — kept `unsigned long` locally because vendored DirectSound header's
  GetSpeakerConfig API takes its own non-DWORD pointer.

**Verification — the smoking gun.**
- Before sweep: Logic CRC frozen at `13EF9048` for frames 100→1100
  (sim was a brick; AI hatched nothing; player saw `$10000` starting
  cash and an empty map; no objects updated → no CRC change → user
  reported "enemies dead on spawn", "units never die in cutscenes",
  campaign segfault).
- After sweep: Logic CRC changes every 100-frame snapshot
  (077A33A6 → 2E428476 → C1E0D96B → 537A0A08 → 24CEBE96 → ...). Frame
  600 of auto-skirmish shows `$9500` (player AI spent money), build
  queue active, multiple buildings on map. **Sim is alive.**

**Engine-touch discipline.** SHIM-ONLY rule formally lifted by user
("я можу зняти обмеження, це ж порт"). All edits are Win32-ABI-correct
and either `#if __APPLE__`-gated or behaviour-neutral on Windows.

---

## ▶ Campaign segfault — FIXED (2026-05-25)

User reproduced campaign-start segfault under lldb on USA Mission 1.
Stack trace:
```
W3DShroud::getShroudLevel(this=..., x=48, y=-1) at W3DShroud.cpp:269
  UnsignedShort pixel = *(UnsignedShort *)((Byte *)m_srcTextureData
                          + x*2 + y*m_srcTexturePitch);
```

**Root cause.** `getShroudLevel(Int x, Int y)` bounds check is
`if (x < m_numCellsX && y < m_numCellsY)` where both `x/y` and the
fields are **signed** Int. With y = -1 the check passes (`-1 < N` is
true). The arithmetic line then computes `y * m_srcTexturePitch` where
`m_srcTexturePitch` is `UnsignedInt` → the multiply promotes y to
unsigned → ~4GB offset. On Win32 32-bit pointers wrap inside the 4GB
address space and the read lands somewhere mapped (returns garbage, no
crash). On macOS 64-bit pointers DO NOT wrap → EXC_BAD_ACCESS at the
moment a water vertex's cell coord rounds negative.

Caller: `getRiverVertexDiffuse` in `W3DWater.cpp:183-184` divides world
X/Y by `shroud->getCellWidth/Height()` without clamping — water tiles
along the map edge produce a negative cellY routinely.

**Fix.** Add low-side bounds check `x >= 0 && y >= 0` to both
`getShroudLevel` and `setShroudLevel`, in BOTH `GeneralsMD/.../
W3DShroud.cpp` AND `Generals/.../W3DShroud.cpp`. No-op for non-negative
input; matches the spirit of the existing `x < m_numCellsX` clamp.

User confirmed: campaign now starts. Cutscenes still broken
(separate Bink video pipeline issue).

---

## ▶ DXMT-referenced subsystem hardening (2026-05-25)

User added a cloned + cix-indexed copy of **DXMT** at
`/Users/dvcdsys/Cursor/dxmt` as a reference implementation. Working
through the five subsystems where DXMT covers the same ground we do.
**Methodology:** for each subsystem, audit our coverage against DXMT's
canonical mapping, fix only the real gaps, document the audit.

| # | Subsystem | Status | What landed |
|---|-----------|--------|-------------|
| A | Sampler descriptors | ✅ done | **Plumbed `D3DTSS_MAXANISOTROPY` + `D3DTSS_BORDERCOLOR`** (engine's `TextureFilterClass::_Set_Max_Anisotropy` actually sets these but they were dropped on the floor → anisotropic filter silently downgraded to linear, BORDER addressing produced transparent-black instead of the engine's chosen colour). Added `MetalDrawCall::maxAnisotropy` / `borderColor` fields, `PickBorderColor()` 3-preset snap (mirroring `dxmt/src/d3d11/d3d11_state_object.cpp:758-777`), `MapAddressMode` BORDER → `ClampToBorderColor` (was `ClampToZero`), sampler-cache key promoted uint16→uint32 to include aniso/border buckets. `sd.maxAnisotropy` only enabled when the engine asked for `D3DTEXF_ANISOTROPIC` (matches DXMT pattern). Verified: 25 s skirmish, 6 frames, no regression. |
| B | Depth-stencil descriptors | ✅ audit-only | Already complete: `DSKey` covers zTest/zWrite/zFunc and the full stencil set (func/ref/readMask/writeMask/fail/zfail/pass). Single-sided is correct — D3D8 doesn't have two-sided stencil (that's D3D9-era). DXMT's mapping table matches ours. No gaps. |
| C | Pipeline state cache | ✅ audit-only | uint64 cache key over FVF + blendEn + srcBlend + destBlend + posFloats + uvOff + writeOn. MSAA dimension handled by full-cache-flush on toggle (DXMT does the same). No bug-shaped gaps. |
| D | BC/DXT texture upload | ✅ audit-only | BC1/BC2/BC3 → `MTLPixelFormatBC{1,2,3}_RGBA` in `CreateTextureFmt`; uploads use `MetalContext_UploadTextureRaw` with block-row pitch. Mapping matches DXMT format table. Native, no CPU decode. No gaps. |
| E | MSAA infrastructure | ✅ audit-only | Sample count 1/2/4/8; both colour + depth MSAA textures use `MTLStorageModeMemoryless` (canonical TBDR pattern, same as DXMT). `rasterSampleCount` matched to attachment count, with capability check fallback. `MTL_MSAA` env override + runtime `SetMSAA`. No gaps. |
| F | MSL FF combiner | ✅ audit-only | Covers MODULATE/2X/4X, SELECTARG1/2, ADD, ADDSIGNED/2X, SUBTRACT, ADDSMOOTH, MULTIPLYADD (stubbed→ADD) + arg modifiers (COMPLEMENT, ALPHAREPLICATE). Rarely-used ops (BLEND*, DOTPRODUCT3, LERP, BUMPENVMAP) fall back to MODULATE, matching the engine's documented default. Add only when a concrete artefact maps to a missing op — no fishing expedition. |

**Rule of thumb established:** when a shim subsystem feels
under-specified, consult `/Users/dvcdsys/Cursor/dxmt` (own cix index)
before guessing. Trial-and-error against the engine costs hours of A/B
captures; reading a working reference takes minutes. See
"DXMT reference project" note above in this file.

---

## ▶ Progress Tracker  (read this first; update it last)

**Workflow for each session:** (1) read this table to find the next `⬜ pending` stage; (2) read that stage's section + the "Stage N — completed work" notes of finished stages; (3) do the work; (4) **update this table** (status + one-line "what landed") and add a "Stage N — completed work" subsection under that stage with the real root causes / changed files, so the next session starts from truth, not guesses.

| Stage | Status | Summary |
|------|--------|---------|
| 0. Baseline (compile + link + Metal M1) | ✅ done | Full native build; `generalszh` Mach-O arm64; Metal window+clear+present (smoketest). |
| 1. Game data loading | ✅ done | Root cause was 4‑byte `wchar_t` corrupting CSF parse — **not** archives/language. 90 `.big` mounted, 6422 strings, boots to `Set_Render_Device`. Debug logging turned ON. |
| 2. Metal 2D → main menu | ✅ DONE — menu fully renders | **The main menu renders correctly: logo, blue frame, and readable buttons (SOLO PLAY / MULTIPLAYER / LOAD / OPTIONS / CREDITS / EXIT GAME).** Three decisive late fixes after text first appeared scrambled: **(1)** `D3DXGetFVFVertexSize` (cmake/dx8_stub/dx8_stub.cpp) used `sizeof(DWORD)` for DIFFUSE/SPECULAR/PSIZE — `DWORD`=`unsigned long`=**8 bytes** on macOS LP64, inflating the FVF stride 44→48; the engine packs `VertexFormatXYZNDUV2` at 44 but stepped at 48 → every vertex past the first misread → "brown smear". Fixed to literal 4. **(2)** Same LP64 trap in **`FVFInfoClass`** (Core/Libraries/Source/WWVegas/WW3D2/dx8fvf.cpp): `texcoord_offset`/`specular_offset` added `sizeof(DWORD)` → texcoord offset 28→32, so `Render2DClass::Render` wrote UVs 4 bytes too far (u landed in v1's slot → u≡0) → all 2D sampled a single texture column. Fixed to `FVF_DWORD_SIZE=4`. **(3)** `gdi_text.mm` `ExtTextOutW` did an extra vertical row-flip when copying the CGBitmapContext to the 24bpp DIB — but CG memory is already top-down and the baseline math handled y-up, so glyphs came out vertically flipped (invisible on symmetric letters, but `S`→`Ƨ`, looked like a horizontal mirror). Removed the flip. **Lesson: `sizeof(DWORD)`/`sizeof(LONG)` in any vertex/format-size math is an LP64 landmine — grep for more.** Earlier groundwork below. |
| 2 (earlier groundwork). | — | **Text now renders too — main menu is readable.** GDI glyph rasterization (FontCharsClass) is backed by Core Text + Core Graphics in `cmake/dx8_stub/gdi_text.mm` (HDC/HFONT/HBITMAP as tagged opaque structs; `CreateFont`→`CTFontCreateWithName`+bold/italic traits; `CreateDIBSection`→24bpp top-down buffer; `ExtTextOutW`→render white-on-black into an RGBA8 `CGBitmapContext` with grayscale AA, then copy the R channel as coverage into the 24bpp DIB with a Y-flip; `GetTextMetrics`/`GetTextExtentPoint32W` from CTFont ascent/descent/advances). Verified: glyphs rasterize with real coverage (covMax=255, space=0). The `BOOL` typedef clash (objc `bool` vs win32 `int`) is sidestepped by importing the frameworks first then `#define BOOL WIN_BOOL` before `windows.h`. **Earlier (2-core):** textured UI geometry draws — see decisive fixes below. |
| 2-core (renderer). | — | **Real 2D rendering works — textured UI geometry draws on screen** (verified visually: UI panels/widgets render in the right places, alpha-blended). Implemented: texture upload (format-aware `LockRect`/`UnlockRect`→BGRA8 `replaceRegion`), DXTC disabled so DDS CPU-decompresses to ARGB, a cached `MTLRenderPipelineState` (MVP vertex shader + tex×diffuse fragment, D3D blend mapping), render-pass lifecycle (clear load-action + lazy encoder + present/commit). **Five decisive fixes:** (a) `D3DXGetFVFVertexSize` was a `return 0` stub → broke vertex stride *and* the engine's own vertex-array stepping; (b) `SetStreamSource` ignored the stream index so stream-1 null releases clobbered stream 0; (c) Metal can't make BC textures (forced `Support_DXTC()=false`); (d) ARC is OFF so per-frame drawable/cmd/encoder needed explicit `retain`/`release`; (e) **`TGA2Footer`/`TGA2Extension` used `long` (8 B on LP64 vs 4) → `sizeof(TGA2Footer)`=34≠26, so the footer read came up short and *every* TGA load failed → all-magenta missing-texture.** Now real textures load (3 of 4 menu textures real). **Remaining (minor / later stages):** the main-menu *backdrop* is the animated 3D shell scene (Stage 4) — its 2D placeholder `mainmenubackdropuserinterface.tga` isn't shipped, so that area shows the magenta missing-texture until Stage 4; and text via Core Text. |
| 3. Input (Cocoa) | ✅ done | **Mouse + keyboard work — the menu is interactive** (verified: clicks where buttons are produce UI reactions). `metal_backend.mm` captures mouse/key NSEvents (in `DrainEvents`) into global queues exposed by `MetalInput_PollMouse/PollKey/CapsOn`. `Win32GameEngine::serviceWindowsOS` (Apple block) drains the mouse queue and synthesizes the exact Win32 messages `Win32Mouse::translateEvent` already understands → reuses all Win32Mouse/W3DMouse logic incl. cursor drawing. New `CocoaKeyboard` (Core, replaces the failing `DirectInputKeyboard` via the Apple `W3DGameClient::createKeyboard` branch) maps macOS `kVK_*` → engine `KeyDefType` (DIK scancodes). Coords: content-view pixels, Y-flipped. **Also:** missing-texture placeholder made fully transparent on macOS (was 50%-magenta) so absent assets (the 3D-shell backdrop, Stage 4) don't veil the screen. |
| 4. Metal 3D fixed-function → gameplay | 🔶 In-game playable; cliff-shroud + infantry textures + tooltip BG + cursor all fixed this session; pre-existing 2D-sprite menu/rect bug + tooltip-text truncation are the remaining open items (see "Session 2026-05-23/24" section) | **★ SHROUD ON CLIFF PEAKS FIXED (2026-05-23)** — TCI_CAMERASPACEPOSITION + D3DTS_TEXTURE0 texture transform now plumbed end-to-end in the Metal shim (`metal_backend.{h,mm}` + `dx8_device.cpp` FillCommon); MSL vs derives `UV=(texXform*view*world*pos).xy` when triple-gate matches (`tciMode==2 && texXformCount>=2 && posFloats==3`). `GEN_NO_SHROUD=1` opts out. **★ INFANTRY TEXTURES FIXED (2026-05-23)** — `W3DModelDraw::replaceIndicatorColor` short-circuits on macOS by default; root cause is broken LockRect/UnlockRect round-trip for ARGB1555/4444 inside `Recolor_Texture`. `GEN_HOUSECOLOR=1` re-enables. **★ TOOLTIP HUGE-RECT FIXED (defensive, 2026-05-23)** — `W3DDisplay::drawFillRect/drawOpenRect` clamp |w|/|h| > 4096 → skip. Deeper bug is in `Render2DSentenceClass` cursor state across chunks (per-char widths are correct, but tooltip text still only shows first char — open item). **★ CURSOR FIXED (2026-05-23)** — `osdep_compat/win32_api.h` `SetCursor`/`ShowCursor`/`SetCursorPos`/`LoadCursorFromFile` now wire to `MetalCursor_Show`/`MetalCursor_WarpClient` (Cocoa NSCursor + CGWarpMouseCursorPosition). System cursor hides when engine wants software cursor, click positions in sync. **★ WATER DEPTH-ORDERING FIXED** — `MTL_ZDUMP` found EVERY FVF had `zEn=0`. Root cause: WW3D2's `DX8Wrapper::Apply_Default_State()` is defined but NEVER CALLED; `ShaderClass::Apply()` sets ZFUNC and ZWRITE but NOT ZENABLE — assumed Windows D3D8's hardware default of `D3DZB_TRUE`. The Metal shim's zero-init left ZENABLE=0 forever, so no draw depth-tested; 3D looked vaguely right via submission order, and water (drawn last) painted over helicopters/ships. Fix: seed `m_renderStates[D3DRS_ZENABLE]=TRUE` in `MetalDevice8` ctor. Narrowed to ZENABLE only (full D3D8-defaults seeding broke in-game). `MTL_DEPTH_OFF=1` opt-out. Verified shellmap (proper depth) + in-game skirmish (no regression). **★ SHELLMAP WATER "BLACK GRID" FIXED** — root cause was `drawTrapezoidWater`'s fallback shroud-on-water SECOND pass (taken when `m_trapezoidWaterPixelShader==0`, our macOS state since PS caps are 0): it re-draws the trapezoid mesh with the SHROUD texture + `ST_SHROUD_TEXTURE` multi-stage shader, which the Metal FF shim doesn't emulate → near-opaque dark tiles paint over the (correct) first water pass. Fix: `#if defined(__APPLE__)` skip the fallback pass in `Core/.../W3DWater.cpp` (~line 3383); `GEN_WATER_SHROUD_PASS2=1` opts back in for A/B. Now shellmap shows clean translucent blue water with ships visible underneath; in-game skirmish unaffected. See top section for full diagnostic methodology. **★ TEXTURES NOW LOAD — the "all models black/untextured" bug is fixed (516 missing textures → 1).** Root cause was **another LP64 trap** (PLAYBOOK #1): `GeneralsMD/.../WW3D2/ddsfile.h` `LegacyDDSURFACEDESC2` had `void* Surface;` — a **4-byte on-disk DX7 `lpSurface` placeholder** that becomes **8 bytes + 8-byte-aligned on LP64**, so `sizeof(LegacyDDSURFACEDESC2)` ≠ 124. `DDSFileClass` ctor reads the header then checks `read_bytes != SurfaceDesc.Size(=124 from disk)` → **EVERY `.dds` load failed** → the loader fell back to the `.tga` (which doesn't exist on disk — ZH ships skins as `.dds`) → all unit/building/terrain skins became the (transparent/black) missing-texture placeholder → black models. Fix: `void* Surface;` → `unsigned Surface;` (never used as a pointer; 4 bytes on both Win32 and LP64 → no-op on Windows). **Plus** re-enabled **native BC/DXT texture support** (`cmake/dx8_stub/dx8_device.cpp` `CheckDeviceFormat` now returns OK for `D3DFMT_DXT1..5` — the earlier "Apple Silicon can't make BC textures" comment was WRONG; `device.supportsBCTextureCompression==YES` on M1+, verified on M3 Max). The Metal backend now creates `BC1/BC2/BC3_RGBA` textures and uploads compressed blocks verbatim (`MetalContext_CreateTextureFmt`/`MetalContext_UploadTextureRaw`; `MetalTexture8`/`MetalSurface8` carry a compressed path: staging sized as tightly-packed BC blocks, block-row pitch, no conversion). **VERIFIED:** `GEN_MODEL_VIEWER GEN_MODEL=ABBarracks_AC` shows the American-flag skin (red/white stripes + blue field) instead of a black silhouette; in a live `GEN_AUTO_SKIRMISH` the terrain renders with real rock tile textures + the full HUD; 516 "Targa: Failed to open" → **1** (`trstrtholecvr.tga`, a genuinely-absent road decal). Note: the ddsfile.h fix is the *essential* one (the DDS header parse failed regardless of DXTC); native BC is the GPU-native bonus (less memory, no CPU decode) and is what made `Get_Valid_Texture_Format` keep the DXT format. **Earlier groundwork:** **The animated 3D main-menu shell-map backdrop renders** (terrain with real tile textures, depth, perspective — verified via `/tmp/gen_frame_*.png`). Built the full FF 3D renderer in the shim: **depth buffer** (`Depth32Float` attachment + depth-stencil state cache honoring `D3DRS_ZENABLE/ZWRITEENABLE/ZFUNC`), **generalized FVF** (POSITION required; NORMAL/DIFFUSE/TEX0 optional — flagged on/off via uniforms; vertex descriptor now 4 attrs), **backface culling** (`D3DRS_CULLMODE`, front=CW), and **FF vertex lighting** in MSL (material diffuse/ambient/emissive, `D3DMCS_*` color sources, global ambient, ≤8 directional/point lights; no-normal geometry gets ambient/emissive only — D3D doesn't do N·L without a normal). Files: `cmake/dx8_stub/{metal_backend.h,metal_backend.mm,dx8_device.cpp}`. **Two decisive non-renderer root causes that were blocking the whole backdrop:** (1) **`cpudetect.cpp` on Apple Silicon** — `Init_Memory()` was never called (it sits behind `Has_CPUID_Instruction()`, false on arm64) so `TotalPhysicalMemory=0`, and `Init_Processor_Speed()` derived a bogus ~24 MHz from the arm64 cycle counter (CNTVCT timebase, not CPU clock). `GameLODManager` then saw `!m_memPassed || isReallyLowMHz()` and **disabled the shell map** (`GameLOD.cpp:621`), so no 3D scene ever loaded. Fixed: `__APPLE__` branch calls `Init_Processor_String/Features/Memory` (sysctl `hw.memsize`) + reports a representative 3000 MHz. (2) **Terrain tile textures live in the BASE Generals install**, not the ZH BIGs — ZH is an expansion. `WorldHeightMap::readTexClass` opens `Art/Terrain/*.tga` which only exist in `Command and Conquer Generals/Terrain.big` (+`Textures.big`,`W3D.big`). Mounted by **symlinking those 3 base BIGs into the ZH working dir** (do NOT symlink INI/English/Audio/etc — they collide with the ZH versions and crash init). **Gotcha (cost an hour):** terrain writes **dest alpha 0** (vertex-color alpha 0, opaque draw) so the PNG frame dumps looked all-white (transparent over white viewer bg) even though RGB was correct desert terrain — fixed by `layer.opaque=YES` + forcing alpha 255 in the dump. **Remaining:** main-menu **buttons** don't composite over the shell backdrop (only the logo does); was fine before the shell map was enabled — likely the MainMenu intro `AnimateWindowManager` slide-in is stuck (buttons parked off-screen). Models/units/in-game terrain untested (needs entering a skirmish). **IN-GAME (skirmish) follow-ups landed:** (a) **`DataChunk.cpp` `readUnicodeString`/`writeUnicodeString`** — on-disk unicode is 2-byte UTF-16 but `WideChar`=`wchar_t`=4 bytes on macOS, so it read `len*sizeof(WideChar)`=`len*4` and **over-read 2×**, shifting every subsequent field → corrupted build-list building names (`'ypoint304_Station'` = shifted `Waypoint304_Station`). Fixed to read/write 2-byte and widen/narrow (the `sizeof(WideChar)==2` branch is the original Windows path → pure-correctness). Verified: 0 build-list errors. (b) **`W3DTreeBuffer::addTreeType` returned `0` on failure** (model load fail) but `addTree` skips only on `<0`, so a failed tree model aliased valid tree-type 0 → `m_treeTypes[0].m_data==null` → **EXC_BAD_ACCESS crash** in `unitMoved` when a unit moved near a tree. Once the unicode fix made maps parse correctly, units actually spawned/moved → triggered it. Fixed: failure returns `-1`. Verified: game now survives in-game (`-file "Maps\Alpine Assault\Alpine Assault.map"`, runs past frame 900). **Diagnosed (NOT bugs):** the in-game "terrain holes" are the **shroud / fog-of-war** (pixel sample: revealed cells = terrain RGB, unexplored = pure black `0,0,0`; log: `Reveal shroud for Observer`) — terrain renders correctly where revealed; hard grid edges because shroud-blend `TSNoiseUrb.tga` isn't found. The W3D loader is fine — only **7** special/missing assets fail (`Locater01`,`SCMNode`,`SCMoveHint`,`new_skybox`,`avamphib*` — same as Windows); the 1708 "Old format mesh" + garbage-chunk-id spam is those 7 retried every tick. Debug env added: `MTL_NOCULL`,`MTL_TEXONLY`,`MTL_SKIP3D`. **IN-GAME RENDERING VERIFIED (skirmish):** added `GEN_AUTO_SKIRMISH` to boot straight into a 1v1 skirmish (see DEBUG TOOLING) — frame dumps show **in-game terrain (rocky cliffs w/ real tile textures, depth, perspective) + the full control-bar HUD + radar/minimap + command buttons all render correctly**, and the game runs a stable sim loop **past frame 2700**. **Crash fixed:** `W3DWaypointBuffer::drawWaypoints` (`GeneralsMD/.../W3dWaypointBuffer.cpp`) dereferenced `m_waypointNodeRobj` (the `"SCMNode"` render object) which is **null on macOS because SCMNode is one of the 7 assets that fail to load** → null-deref EXC_BAD_ACCESS during terrain render (`HeightMapRenderObjClass::Render`→`drawWaypoints`) the moment a unit/building with a rally point or goal-path got drawn (≈frame 200). Guarded all 6 `m_waypointNodeRobj->` deref sites with `if(m_waypointNodeRobj)` (pure robustness; no-op on Windows where SCMNode loads). **Investigated the 7 failing assets — NOT a macOS bug, do not chase:** `SCMNode`/`Locater01` *do* exist in `W3D.big`/`W3DZH.big` (binary-grep confirmed), so they're not missing files. But the W3D `ChunkHeader` is fixed-width **`uint32` `ChunkType`/`ChunkSize`** (`WWLib/chunkio.h` — *not* an LP64/`long` trap), and the vast majority of W3D meshes load correctly through the same reader, so the header parse is sound. These 7 are genuinely **old-format / unsupported** dev meshes: `MeshModelClass::Load_W3D` (`meshmdlio.cpp:246`) sees the first sub-chunk ≠ `W3D_CHUNK_MESH_HEADER3` → "Old format mesh" → `goto Error` (which leaves the stream slightly misaligned, so the *next* `Open_Chunk` then reports a garbage/`256`/`8388608` chunk id → "Unknown chunk type"). This is the **same** rejection retail Windows does — the engine is designed to tolerate `Create_Render_Obj` returning null; the only place that didn't was `W3DWaypointBuffer` (now guarded). So there's no loader to "fix"; the spam is cosmetic. The one with a visible cost is `new_skybox` (no sky dome) — if a sky is wanted later, supply/convert a HEADER3-format skybox mesh rather than touching the loader. **★ THAT EARLIER CONCLUSION WAS WRONG — the real bug was much bigger: W3D model loading was UNIVERSALLY broken on macOS, not 7 assets.** Root cause: **`bittype.h` typedef'd `uint32`=`unsigned long` and `sint32`=`signed long`, which are 8 bytes on macOS LP64** (vs 4 on Win32). Every W3D struct (`W3dMeshHeader3Struct`, all of `w3d_file.h`) and the `ChunkHeader` (`chunkio.h`) is built from these types, so `sizeof()` was doubled → `cload.Read(&hdr, sizeof(hdr))` over-read → the W3D chunk stream desynced from the first chunk → "Old format mesh" + garbage chunk ids (e.g. `1098907648`=`0x41800000`=the float `16.0`, i.e. it was reading vertex floats as chunk headers) → **`Create_Render_Obj` returned null for ~every unit/building/vehicle**. Nothing 3D ever rendered in-game (terrain is procedural geometry, not a W3D file, so it masked the bug — that's why the shell-map "worked"). **Fix:** `bittype.h` — on `__APPLE__`, `typedef unsigned int uint32; typedef signed int sint32;` (true 32-bit; no-op on Win32 where `long` is already 32-bit). Same LP64 class as the `TGA2Footer` bug. Knock-on: `WWSaveLoad/persistfactory.h` saved an object pointer as a `uint32` token and *read it back* as `sizeof(T*)`; with `uint32` now 4 bytes that became asymmetric on macOS, so fixed both sides to round-trip a 32-bit token via `uintptr_t` (no-op on Win32). **VERIFIED:** `ABBarracks_AC` loads (42 polys, bsphere computed) and renders as a correct 3D silhouette via the new `GEN_MODEL_VIEWER` debug mode; in a real auto-skirmish, **units, buildings and vehicles now render on the battlefield** and the sim runs stably past frame 2000 with **0** "Old format"/"Unknown chunk" errors (were 812 + 2004). **Debug mode added:** `GEN_MODEL_VIEWER=1` (+ `GEN_MODEL=<name>`, default `ABBarracks_AC`) in `W3DDisplay::draw()` renders ONE render object through `SimpleSceneClass`+`CameraClass` to isolate the mesh path from the in-game scene — this is how the bug was localized. **Remaining (texture/material polish):** in the isolated viewer the mesh is a solid black silhouette (geometry/depth/raster correct, but no texture/material/diffuse color — the synthetic scene has no lights); in-game with real lights some objects are properly shaded while others look flat/untextured — next step is the W3D-mesh material+texture binding through the FF Metal path. |
| **Advanced Display Options sweep** (Custom-menu checkboxes — see section above) | 🔶 in progress | 10 checkboxes total: 3 ✅, 1 ⬛ untested, 6 ⬜ broken/artefacts. Working through one at a time, no engine UI changes. Shim shadow + MSAA infrastructure pre-built; awaits hookup as part of the relevant rows. |
| 5. Audio (Miles-API impl on AVAudioEngine) | ⚠️ REGRESSED (2026-06-01) — was audible, now SIGBUS at engine init | **★ REGRESSION (2026-06-01).** Audio now crashes the process. Two distinct findings this session: **(1) FIXED a real heap overflow** — stereo IMA-ADPCM decode in `AIL_decompress_ADPCM` wrote ~2× past the `dst` malloc (used `g*16` sample stride + advanced `outIdx` by `groups*32`, but the allocation was sized for `groups*16`; e.g. 2018 int16 into a 1010-int16 region per 512-byte block). The malloc-heap corruption surfaced later as `EXC_ARM_DA_ALIGN` in caulk's audio-buffer pool on `AVAudioPCMBuffer` dealloc inside `AIL_set_3D_sample_file` (the `playSample3D` crash the user hit). Fixed to `g*8` stride / `outIdx += groups*16` + defensive bounds clamps on both mono & stereo paths. This corruption ran **regardless of `MILES_APPLE_NOENGINE`** (decode is independent of the engine), which is why the user saw it "even without sound". **(2) OPEN — AVAudioEngine init SIGBUS (was task #30).** `EXC_ARM_DA_ALIGN` / possible-PAC-fault deep in CoreAudio `ListenerMap::forEachBindingForEvent` ← `AUListenerAddParameter` ← `-[AVAudioMixerNode didAttachToEngine:]` ← `-[AVAudioEngine mainMixerNode]` ← `ensureEngineRunning` ← `AIL_quick_startup`, i.e. at the very first audio call, before any sample is decoded. **NOT CWC-specific — reproduces identically in VANILLA ZH with audio ON (exit 138).** User context: audio was perfect until the Bink/FFmpeg (Stage 6) work began, AND macOS was updated to 26.5. Leading hypotheses: (a) macOS 26.5 AVAudioEngine regression, (b) pre-init heap corruption introduced by the FFmpeg video path that only surfaces in CoreAudio's allocator. Reorder (touch `outputNode` before `mainMixerNode`) did NOT help. Next steps: build with libgmalloc/ASan to determine ours-vs-OS; minimal standalone AVAudioEngine init test to isolate an OS regression; if pure OS bug, consider an AudioQueue / CoreAudio-HAL backend that avoids the `mainMixerNode`/AU-listener path. **Workaround: `MILES_APPLE_NOENGINE=1` = stable + silent** (this is what `make run-cwc` uses). --- **★ STAGE 5 LANDED (2026-05-31)** — Strategy A from the plan: replaced the upstream `miles-sdk-stub` (no-op) with a real Miles SDK implementation in `cmake/miles_apple/` (CMakeLists + `miles_apple.mm` + copy of `mss/mss.h`), drop-in for the engine. **Zero engine changes** — `MilesAudioManager.cpp` builds + runs unchanged. **Backend:** `AVAudioEngine` (mixing/output) + `AudioToolbox` `ExtAudioFile` (MP3/WAV decode via in-memory callbacks). **What plays:** main-menu music, UI clicks, weapon SFX, unit voices (3D w/ manual pan + distance attenuation), looping music, fading streams. **`cmake/miles.cmake`** gates `APPLE → add_subdirectory(cmake/miles_apple)` else FetchContent the upstream stub; downstream `corei_gameenginedevice_public → milesstub` link is unchanged. **6 root-cause fixes in the AVFoundation glue (Sequoia / M-series):** (1) **mainMixer rate mismatch**: AVAudioEngine lazily wires mainMixer→outputNode at *44.1 kHz default* before the env/player attach, but outputNode is *48 kHz* — connection silently zeroes → no audio. Fix: explicit `disconnectNodeOutput:mainMixer` + reconnect at `outputNode.outputFormatForBus:0` (48 kHz) in `ensureEngineRunning`. (2) **Voice pool overflow**: Miles preallocates 4×2D + 32×3D handles up front; attaching all 36 `AVAudioPlayerNode`s to a running engine triggers an internal abort. Fix: lazy node creation — `AIL_allocate_*_handle` returns a handle with `node=nil`; node is allocated in `AIL_set_*_sample_file` only when a file is actually bound. (3) **"Player started when in a disconnected state"**: reused `AVAudioPlayerNode` enters a permanent disconnected state after the first `play → completion → re-schedule` cycle on Sequoia, even with the node still attached + connected (verified via `attachedNodes` + `outputConnectionPointsForNode`). Fix: detach old node + alloc/attach a fresh node on every file bind. Expensive but reliable; Miles only re-binds at event start, never on the audio thread. (4) **`AVAudioPlayerNode -reset` triggers the same disconnect**: deliberately not called in `stopAndDetach` (only `-stop`). (5) **`AVAudioEnvironmentNode` is unusable on M-series for *any* rendering algorithm** (HRTF / EqualPowerPanning / Sphere all throw the disconnected-state exception even with the fresh-node + try/catch infra). We route 3D voices flat through `mainMixer` and do **manual pan + distance attenuation** in `apply3DPanAndVolumeForSource`: `right = forward × up`, `pan = (delta · right_normalized) / maxDistance` (clamped ±1), `volume = sourceVol × (dist ≤ minD ? 1 : dist ≥ maxD ? 0 : minD/dist)`. For a top-down RTS this matches what a player expects and **rotates with the camera** (listener forward+up tracked in `AIL_set_3D_orientation`). (6) **IMA-ADPCM round-trip**: `AudioFileCache::openFile` calls our `AIL_decompress_ADPCM` then hands back a *raw PCM pointer* (no WAV header) via `AIL_set_(3D_)sample_file`. `parseWav` would fail and `decodeFullyToPCM` (AudioToolbox) can't read raw PCM either. Fix: `g_imaBlobs` registry maps the decompressed pointer → `{channels, rate, size}`; `set_sample_file` checks the registry first and builds an `AVAudioPCMBuffer` directly. `AIL_mem_free_lock` unregisters. **Robustness:** every `[engine attach]`/`[engine connect]`/`[engine detach]`/`[player schedule]`/`[player play]` site is `@try`/`@catch`-wrapped; the catch logs `ex.name`+`ex.reason` and bails the operation rather than letting the NSException unwind into `GameEngine::update` (which previously surfaced as the generic `Uncaught Exception in GameEngine::update` → `Technical Difficulties` MessageBox). **Performance:** music streams are decoded into a **`g_streamCache`** keyed by filename (LRU cap 3) — `MilesAudioManager::getFileLengthMS` opens the stream once just to measure length, then the engine opens it again for playback; without the cache that double-decoded every track (~3 s + ~67 MB float32 stereo per 3-min MP3). Cache hit logged as `AIL_open_stream(...): cache hit`. **Files:** `cmake/miles_apple/CMakeLists.txt`, `cmake/miles_apple/miles_apple.mm` (~1500 LOC Objective-C++), `cmake/miles_apple/mss/mss.h` (copy of upstream header), `cmake/miles_apple/cleanup.c` (copy). **Debug envs:** `MILES_APPLE_LOG=1\|2` (chatty/lifecycle), `MILES_APPLE_MUTE=1` (silent but cycles handles so EOS still fires), `MILES_APPLE_NOAUDIO=1` (refuse all streams — for isolating the audio path), `MILES_APPLE_NOPOOL=1` (refuse pool handles — useful when bisecting graph-mutation crashes), `MILES_APPLE_NOENGINE=1` (skip `AVAudioEngine` startup entirely — pure stub mode), `MILES_APPLE_1STREAM=1` (cap concurrent streams to 1). **Open holes** (not blockers — fix as encountered): HRTF spatialisation deferred (manual stereo pan instead — RTS top-down is OK with this); `AIL_set_3D_sample_distances` uses the *latest* source's min/max for env model — moot since env is unused, but the per-source falloff is correct; ~~`AIL_set_sample_ms_position` is a stub~~ (now implemented for 2D/3D/stream via buffer-slice + `generation`-bumped reschedule, 2026-05-31); rare segfault when opening main menu reported once by user (no crash log captured yet — needs `~/Library/Logs/DiagnosticReports/generalszh-*.crash` next time it happens). ~~Stable crash on ScoreScreen after mission end~~ — **FIXED (2026-05-31)** — UAF in `g_device.pendingCallbacks`: when `Display::stopMovie → AIL_close_stream → delete s` ran for a cutscene stream, its loop-continuation block (queued from the AVAudio completionHandler at miles_apple.mm:1541) was still in the queue; engine's next `MilesAudioManager::update → AIL_set_sample_file → drainCallbacks()` fired the block, which did `[s->node …]` on the freed stream → `EXC_BAD_ACCESS in libobjc lookUpImpOrForward`. lldb trace was decisive (frames 2→3→4→5 told the whole story). Fix: liveness registry `g_aliveHandles : unordered_set<void*>`, callback queue typed as `(owner, cb)` pairs; `markAlive` at `AIL_allocate_*_handle / AIL_open_stream`, `markDead` **before** `delete` at `AIL_release_*_handle / AIL_close_stream`; `drainCallbacks` skips any block whose owner is no longer alive. Safe in our single-threaded engine-update model: release and drain are on the same thread, so the check + use can't race. **Verified:** game runs 20s+ from skirmish boot with **0 NSException, 0 decode failures** under `MILES_APPLE_LOG=2`; main-menu music plays via cache hit; user confirmed audible playback. |
| 6. Video (FFmpeg) | 🔶 in progress — decode + texture path wired, audio TBD | **★ STAGE 6 KICKED OFF (2026-05-31)** — FFmpeg 8.0.1 (Homebrew) wired into the apple-arm64 preset; intro cutscenes decode without crash. **Changes:** (1) **`cmake/FindFFMPEG.cmake`** — new pkg-config-driven `find_package(FFMPEG)` module (engine's `Core/GameEngineDevice/CMakeLists.txt:233` already calls `find_package(FFMPEG REQUIRED)` when `RTS_BUILD_OPTION_FFMPEG=ON`, but no `FindFFMPEG.cmake` existed in-tree — wraps `pkg_check_modules` for `libavformat`/`libavcodec`/`libswscale`/`libavutil` + optional `libswresample` and exposes `FFMPEG_FOUND/INCLUDE_DIRS/LIBRARY_DIRS/LIBRARIES`). (2) **`CMakePresets.json`** — `apple-arm64` preset now sets `RTS_BUILD_OPTION_FFMPEG: ON`. Result: `corei_gameenginedevice_public` gets `RTS_HAS_FFMPEG` defined → `W3DGameClient::createVideoPlayer()` returns `FFmpegVideoPlayer` instead of the no-op `BinkVideoPlayer` (binkstub). **Decode path verified live:** smoke run logs show `FFmpegVideoPlayer::createStream()` opening `Data/english/Movies/EA_LOGO.bik` + `sizzle_review.bik`; swscale runs every frame (warning `No accelerated colorspace conversion found from yuv420p to bgra` is a perf-only advisory, not a blocker). `otool -L` shows the binary linked against the right dylibs (libavformat.62, libavcodec.62, libswscale.9, libavutil.60, libswresample.6). **Render path is the existing 2D quad pipeline:** `FFmpegVideoStream::frameRender(buffer)` → `sws_scale` writes BGR0 into `W3DVideoBuffer::lock()` → `TextureClass` surface → dx8_stub `LockRect`/`UnlockRect` → Metal texture. `W3DDisplay::drawVideoBuffer` calls `m_2DRender->Add_Quad(rect, vbuffer->texture())` — same code path Stage 2 already exercises for the menu. **Perf regression caught + fixed in the same session (2026-05-31):** user reported 7-10 FPS / >100% CPU once FFmpeg was on, then 40-120 oscillation after the first fix. `sample(1)` walked three layers of per-frame allocation + a missing VSync pin: **(1) MetalSurface8 ctor zero-init** of full 14.7 MB back-buffer staging (47% CPU on menu); **(2) per-frame BGRA conversion scratch** in flushToTexture (37% CPU on loadscreen video); **(3) CAMetalLayer maximumDrawableCount=3 with no explicit displaySyncEnabled** letting CPU race 3 frames ahead before VSync blocked (ragged 40-120 oscillation). Fixes in dx8_stub: lazy staging, persistent m_bgraScratch, `displaySyncEnabled=YES` + `maximumDrawableCount=2`. See "Cross-cutting perf fix series" under Stage 2's "Remaining" section for the full writeup. Post-fix sample shows `FramePacer → Sleep → __semwait_signal` at 79% of main-thread time — engine throttles itself, framerate steady at refresh rate. **What remains:** (a) **visual verification** — needs the user (cutscenes appear on screen, scale correctly, are skippable with ESC/click). (b) **audio** — `FFmpegVideoStream::onFrame`'s audio branch is `#ifdef RTS_USE_OPENAL` only. On macOS the cutscene plays silent (or whatever the music track still routes through Miles). Wiring options: define `RTS_USE_OPENAL`+stub `OpenALAudioStream` over our Miles shim (smallest engine touch), or add `RTS_USE_MILES_FFMPEG_AUDIO` that pumps PCM frames into a Miles HSTREAM, or accept silent for v1 and revisit. (c) **`getHandleForBink`** in our Miles shim is still a stub — matters once audio is wired. **Files:** `cmake/FindFFMPEG.cmake` (new), `CMakePresets.json` (1 line). Engine code unchanged. |
| 7. Polish / persistence / packaging / QA | ⬜ pending | |

Legend: ✅ done · 🔶 in progress · ⬜ pending.

---

## ▶ Render perfection sweep — STATE ✅

After the two water fixes (depth-test + shroud-pass2 skip), I swept the rendering
end-to-end across:

- **Shellmap intro** (frames 0000…3600) — naval battles, cityscape with bridges,
  helicopters, explosions, crater terrain. Water sits BENEATH ships, helicopters
  fly ABOVE water, vehicles move on the bridge — all depth ordering correct, no
  black grid, no broken tiles. The lower-left half-tone "water tile" pattern
  visible in frame 0060 is the natural texture tiling of `TWWater01` (not an
  artifact — the 37×40 trapezoid mesh tiles the texture across the polygon).
- **Main menu** (`GEN_QUICK_MENU=1` debug bypass added in `GameEngine::init`,
  Apple-only) — logo, six menu buttons (SOLO PLAY / MULTIPLAYER / LOAD /
  OPTIONS / CREDITS / EXIT GAME) and the static `MAIN_MENU_BG.tga` battle scene
  composite cleanly over the live shellmap backdrop. Button borders, text,
  layout — all OK.
- **In-game skirmish** (`GEN_AUTO_SKIRMISH=1`) on Alpine Assault, Tournament
  Lake, Seaside Mutiny — terrain, defensive walls, units, HUD, minimap render
  correctly. No black blobs, no missing draws. Shroud renders as expected.
- **Model viewer** (`GEN_MODEL_VIEWER=1 GEN_MODEL=AVHummer`) — Hummer with
  proper desert skin, detailed wheels/turret, headlight cone projecting
  forward. FF lighting and texturing work.
- **`MTL_TESTCLEAR=1`** (blue clear color) — confirmed only the SKY area is
  unrendered (no skybox model — see remaining items). All terrain, units, water
  pixels are covered.

### Cross-cutting perf fix series (2026-05-31, surfaced during Stage 6)

Three independent allocations were burning per-frame CPU on the menu /
loadscreen / cutscene paths, plus a missing VSync explicit-config caused
ragged 40-120 FPS oscillations on top. All landed in the same session as
FFmpeg was first switched on. Together: ~50% main-thread CPU idle → ~80%
idle, framerate steadied around the display refresh rate (60 Hz on most
Macs, 120 Hz on ProMotion).

**1. `MetalSurface8` lazy staging.** `dx8_stub`'s `MetalSurface8(w,h,fmt)` ctor used to
`m_staging.resize((size_t)pitch * h, 0)` immediately — for a screen-sized back
buffer at 2560×1440×4 that's **14.7 MB zero-filled per allocation**. The engine
calls `DX8Wrapper::_Get_DX8_Back_Buffer()` (which `new`s a fresh `MetalSurface8`)
**every frame from `W3DSmudgeManager::render`** even when no smudges exist
(the common case in menus / cutscenes / shellmap), then `Release_Ref`s it
straight away. Sample(1) profile showed `std::vector::__append` + `__destroy_vector`
at the top of stack consuming **~47% of main-thread CPU** during the main menu
(989/4142 + 889/4142 = 1878 samples). FFmpeg made this visible: pre-FFmpeg the
slack covered it; once FFmpeg started feeding ~30 frames/s of `sws_scale` work
the loop fell off a cliff (7-10 FPS, >100% CPU). Fix:
```cpp
// cmake/dx8_stub/dx8_device.cpp — MetalSurface8 ctor
m_staging_size = (size_t)m_pitch * h;   // remember logical bytes
// ...lazy resize from a new ensureStaging() in surfBits / LockRect / on-demand only
```
With the fix the menu sample shows `semaphore_wait_trap` (idle) as the dominant
top of stack — CPU is 60+% idle. The smudge allocation pattern entirely
disappears. **Watch for this pattern elsewhere**: any per-frame fresh `MetalSurface8`
(render-target probe, image surface created/copied/released) shares the same
underlying lazy-alloc property now. **Files:** `cmake/dx8_stub/dx8_device.cpp`
(MetalSurface8 class — ctor + ensureStaging helper + surfBits / LockRect /
GetDesc updated to report the logical size from `m_staging_size`, not
`m_staging.size()`).

**2. Persistent BGRA scratch in `flushToTexture`.** Even with #1, the loadscreen
profile still pinned ~37% main-thread CPU at
`FFmpegVideoStream::frameRender → W3DVideoBuffer::unlock → MetalSurface8::UnlockRect → flushToTexture`,
specifically the `std::vector<unsigned char> bgra((size_t)w * h * 4)` temporary
that BGR0/ARGB-to-BGRA8 conversion writes into before `MetalContext_UploadTextureBGRA8`.
For a typical 800×600 video frame that's 1.9 MB per frame allocated and freed.
Fix: hoist the vector onto the surface as `m_bgraScratch` and `resize()` only
when it grows (the common case is "same size every frame" → single capacity
check, no alloc). Post-fix the flushToTexture path drops from ~1837 to ~25
samples; `ConvertRowToBGRA8` becomes the dominant cost, which is honest work
(per-pixel byte-swap with no SIMD). **Files:** `cmake/dx8_stub/dx8_device.cpp`
(MetalSurface8::flushToTexture + new `m_bgraScratch` member).

**3. CAMetalLayer VSync explicit + drawable-pool cap.** User reported main-menu
background cutscene and mission gameplay jumping between 40 and 120 FPS even
after #1+#2. **Historical context (from user, 2026-05-31):** before the
shadow + 3dfx fixes earlier in Stage 4 / display options sweep, "rendering
was on CPU and the speed looked like the original" — i.e. the *absence* of
3D acceleration was itself acting as the de-facto frame-rate governor, with
CPU-bound rasterisation keeping the loop somewhere near 30 FPS. Once shadows
and the rest of the GPU path came online (a *fix*, not a regression), the
CPU stopped being the bottleneck, the pacer ran uncapped, and the absence of
a proper FPS cap or VSync hookup became visible as ragged framerate. **The
right fix is what this section does — pace on display refresh, not on
incidental CPU exhaustion.** Skirmish was unaffected because the in-game
Options menu has an "FPS limit" toggle that flips `m_useFpsLimit`; outside
skirmish (main menu, mission cutscenes, load screen) there's no UI for it,
so the engine cap was bypassed. CAMetalLayer defaults to `maximumDrawableCount = 3` so the CPU
can race up to three frames ahead of the display before `nextDrawable` blocks;
combined with the engine's busy-spin frame limiter the result is bursty
pacing (heavy frame eats the CPU-ahead budget, next-drawable blocks, lull,
burst, repeat). Skirmish was stable because its options-menu "FPS limit ON"
toggles `m_useFpsLimit` and the engine cap kicks in — outside skirmish (no UI
to set it) the cap is bypassed. Fix in `cmake/dx8_stub/metal_backend.mm`
window-init: explicitly set `displaySyncEnabled = YES` (default but pin it)
and `maximumDrawableCount = 2`. The third frame's `nextDrawable` now blocks
on the refresh-rate deadline so pacing rides VSync. Env overrides:
`MTL_NO_VSYNC=1` (uncapped — profiling), `MTL_DRAWABLES=1..3` (A/B pool
depth). Post-fix sample on the loadscreen-with-video shows
`FramePacer::update → FrameRateLimit::wait → Sleep → __semwait_signal` at
79% of main-thread time → headroom restored, framerate locked to refresh.

### Remaining (not blocking; documented for future polish)

1. **No skybox** — `new_skybox` is one of the seven "Old format mesh" assets
   the W3D HEADER3 loader rejects (same as `SCMNode`, `Locater01`, etc.; see
   Stage 4 notes). Sky shows as the clear color (black, or whatever the engine
   sets) — most visible on desert/terrain shellmap frames (0900/1200) and
   gameplay maps with a high horizon. Real fix: add HEADER1/2 W3D mesh support
   OR ship a converted HEADER3 skybox in the macOS asset symlink set.
2. **`trstrtholecvr.tga`** — one road-decal TGA that's genuinely absent from
   the BIGs we have (likely a manhole-cover overlay). Single decal, invisible
   in shellmap; in gameplay only matters if a unit drives over a specific road
   tile. Same on Windows install.
3. **Shroud on water** — `drawTrapezoidWater`'s fallback shroud-on-water 2nd
   pass is SKIPPED on macOS (it caused the black grid). Effect: in gameplay,
   the water surface itself doesn't darken in unexplored regions; terrain still
   darkens correctly under shroud. Re-enable with `GEN_WATER_SHROUD_PASS2=1`
   for A/B (still broken without ST_SHROUD_TEXTURE multi-stage shader
   emulation). Real fix: implement that shader as Metal multi-pass or sample
   the shroud as a second texture stage in the existing pipeline.

### Render FPS cap (2026-05-31)

`FramePacer::getActualFramesPerSecondLimit()` is overridden on Apple to **pin
render at 30 FPS** in every game state — main menu shellmap, cutscenes,
loadscreen, missions, skirmish, score screen. Reason: the original game was
effectively CPU-bound at ~30 FPS on period hardware; cutscene/idle-anim
timings are tuned to that, and running render at 60+ visibly speeds up
camera moves and ambient idle anims even though logic still ticks at
`LOGICFRAMES_PER_SECOND=30` (logic is decoupled from render rate; units
don't move faster, but visual ramp does). User reported missions floating
~75 (riding VSync slack on a 75 Hz display) with cutscenes dropping to 20
under video-upload load — uneven pacing was the chief complaint. Hard cap
at 30 makes every state feel like the original. Override with
`GEN_FPS_CAP=N` (N>0 → that value; 0/negative → uncapped, returns the
upstream gate behavior). The pre-existing engine state machine still calls
`setFramesPerSecondLimit(20|240)` per state — we just ignore its result and
return our cached cap instead. **Files:** `Core/GameEngine/Source/Common/FramePacer.cpp:106-138`
(single `getActualFramesPerSecondLimit` body wrapped in `#if defined(__APPLE__)`).

### Debug env-vars left in tree (all Apple-only, zero cost off)

**Full catalogue lives in [MACOS_ENV_VARS.md](MACOS_ENV_VARS.md)** — every
`GEN_*` / `MILES_APPLE_*` / `MTL_*` flag in the tree, organised by purpose
(quick-launch, FPS cap, feature overrides, render-stage kill-switches,
shadow tuning, audio shim, Metal backend). Update that file when adding any
new flag; keep this section a brief teaser only.

Most-reached-for flags during the port (the rest is in the catalogue):
- `GEN_QUICK_MENU=1` — skip intro+shellmap, land on main menu fast.
- `GEN_FPS_CAP=N` — render FPS cap (default 30; 0 / negative → uncapped).
- `GEN_AUTO_SKIRMISH=1` + `GEN_AUTO_MAP=Maps\...` — straight to skirmish.
- `MILES_APPLE_LOG=2` — chatty audio shim trace.
- `MTL_DEBUG=1` — verbose Metal log.

---

## ▶ Session 2026-05-23/24 — five in-game render bugs FIXED, two open

This session was driven by user-reported in-game visuals on the live skirmish
(not the shellmap). All four fixes are local, env-var-toggleable, and guard
the macOS branch with `#if defined(__APPLE__)` so the Windows/MSVC build is
untouched.

### 1. Cliff peaks rendering solid black quads — FIXED ✅

Pure-black rectangles with sharp grid-aligned edges appeared on top of rocks
and cliff peaks in-game. `GEN_NO_SHROUD=1` proved it was the shroud overlay
pass (`renderTerrainPass` after the main terrain render).

**Root cause.** `ShroudTextureShader::set` (W3DShaderManager.cpp:1202) configures
stage 0 with `D3DTSS_TEXCOORDINDEX = D3DTSS_TCI_CAMERASPACEPOSITION` and
`D3DTSS_TEXTURETRANSFORMFLAGS = D3DTTFF_COUNT2`, then loads `D3DTS_TEXTURE0`
with an inverse-view × terrain-cell-scale matrix. In D3D8 fixed-function the
input texcoord is generated as the vertex's camera-space position, multiplied
by the stage texture transform; output `.xy` is the final UV. Our Metal shim
was masking off the TCI high bits in `dx8_device.cpp` (`& 0xFF` on the
TEXCOORDINDEX value) — the shroud sampler ended up reading from `TEX0` of
the terrain mesh, which is the terrain ATLAS UV. So it sampled the shroud
texture at terrain-atlas coords, hitting the "fully unexplored" black region
on every high-elevation vertex (small atlas, terrain UVs span the entire
range, peaks → bottom-left = black).

**Fix.** Three files:
- `cmake/dx8_stub/metal_backend.h` — added `tciMode`, `texXformCount`,
  `view[16]`, `texXform[16]` to `MetalDrawCall`.
- `cmake/dx8_stub/metal_backend.mm` — extended `Uniforms` (MSL + CPU
  `UniformsCPU`) with the same fields; `vs_main` computes
  `UV = (texXform * view * world * pos).xy` when
  **all three** of `tciMode==2 && texXformCount>=2 && posFloats==3` hold;
  otherwise pass-through `in.uv`. The triple-gate is essential: terrain
  state leaks into subsequent draws (the engine doesn't reset
  `TEXCOORDINDEX`/`TEXTURETRANSFORMFLAGS` after the shroud pass), and
  XYZRHW (`posFloats==4`) 2D HUD draws would otherwise pick up the TCI
  path and render garbage UVs.
- `cmake/dx8_stub/dx8_device.cpp` `FillCommon` — split
  `D3DTSS_TEXCOORDINDEX` into `texCoordIndex = low16` and
  `tciMode = high16` (was `& 0xFF` only), plumb `D3DTS_VIEW` and
  `D3DTS_TEXTURE0` into `dc.view`/`dc.texXform`.
- `Core/.../HeightMap.cpp` — removed the temporary "skip shroud on macOS"
  guard around `renderTerrainPass`; `GEN_NO_SHROUD=1` remains as an
  emergency opt-out.

**Diagnostic infra left in tree.** `GEN_CLIFF_DEBUG=1` paints terrain cells by
classification (cliff-mapped → green, missing-tile → red, regular-cliff →
blue) in `HeightMap.cpp::updateVB`; `GEN_CLIFF_NOSTRETCH=1` bypasses the OLD
cliff UV-stretching path in `WorldHeightMap::getUVForTileIndex` — both helped
prove the bug was *not* in terrain UV math.

### 2. Infantry textures missing (all factions show black silhouettes) — FIXED ✅

Every infantry unit (and several vehicles) rendered as a flat black model
in-game. The model viewer with `GEN_MODEL=AIRngr_SKN` showed the **same mesh
with correct textures** through the full lighting + combiner pipeline — so
texture loading, mesh rendering, FF lighting, and the FF combiner all work.
The difference between viewer and game: the game calls
`W3DModelDraw::replaceIndicatorColor(playerColor)` for any object with
`OkToChangeModelColor = Yes` (set on infantry/vehicle units), which triggers
`W3DAssetManager::Recolor_Mesh` → `Recolor_Texture`.

**Root cause.** `Recolor_Texture` reads the mesh's source texture surface
(`LockRect` → CPU pixel array), palette-remaps team-color pixels in-place,
then writes the result back (`UnlockRect`). On macOS our Metal shim's
LockRect/UnlockRect round-trip path doesn't currently support every pixel
format the engine uses for character skins (BGRA8 mostly works; ARGB1555 /
ARGB4444 paths break) — the recolored texture comes back as fully-zero or
fully-transparent, so every infantry skin became "missing texture" black.

**Fix.** `Core/.../W3DModelDraw.cpp::replaceIndicatorColor` — `#if defined(__APPLE__)`
early-return after the `m_okToChangeModelColor` check, skipping the recolor
chain entirely. Trade-off: every player's units render with the BASE skin
colour (no team-color uniform tint). Selection-circle, minimap dots, control
bar still show team color (those don't go through `Recolor_Texture`).
`GEN_HOUSECOLOR=1` opts back into the broken path for debugging the
underlying LockRect/UnlockRect bug.

**Proper fix (deferred).** Make `MetalSurface8::LockRect`/`UnlockRect`
correctly round-trip ARGB1555/ARGB4444 (decode on lock, re-encode on
unlock). The current path assumes BGRA8 / BC; small extension.

### 3. Tooltip BG = huge color-tinted rectangle across screen — DEFENSIVE FIX ✅

Hovering over a unit/building produced a giant translucent player-colored
rectangle covering a large screen region. `GEN_DBG_FILLRECT` confirmed the
artifact is `drawFillRect`/`drawOpenRect` called with a huge width: the
`Mouse::drawTooltip` BG box uses `m_tooltipDisplayString->getSize()` for its
dimensions, and that width came back HUGE — root-caused to two adjacent text
metrics issues on macOS:

- The text-render path renders only the **first character** of the tooltip
  ("C" of "Command Center"). Cumulative cursor.X computation in
  `Render2DSentenceClass::Build_Sentence_Not_Centered` advances past
  expected bounds after char 0.
- Char widths from Core Text **are correct** when measured per-char (verified
  with `GEN_DBG_FONT=1`: 'C'=12, 'o'=10, 'm'=17, …). So either the cursor
  state leaks between strings, or `Cursor.X += (TextureOffset.I - TextureStartX)`
  picks up stale `TextureStartX` from a previous string.
- `U+0000` NULL terminator is being measured as a glyph (cx_raw=15) — Core
  Text returns `.notdef` glyph advance instead of 0. Cosmetic; not the cause
  of the cumulative-width blow-up (the loop breaks on NULL before adding it).

**Defensive fix.** `GeneralsMD/.../W3DDisplay.cpp::drawFillRect` and
`drawOpenRect` — `#if defined(__APPLE__)` clamp: if width|height > 4096 or
< -4096, return early (skip the draw). This kills the giant rectangle.
Also added in `render2dsentence.cpp::Store_GDI_Char`: if Core Text returns
`cx > PointSize * 2`, fall back to `PointSize` as a sane default. Tooltip
text itself still shows only the first character — that's the deeper
`Build_Sentence_Not_Centered` cursor-state bug, listed as open below.

**Diagnostic.** `GEN_DBG_FILLRECT=1` logs every drawFillRect with
`|wh| > 100`; `=2` also skips drawcalls > 4000; `=3` skips ALL drawFillRect
(useful to A/B-test which UI element is the culprit). `GEN_DBG_FONT=1` logs
per-character widths returned by Core Text + the final stored Width.

### 4. Dual cursor + click offset — FIXED ✅

Issue: system NSCursor visible alongside the engine's software cursor sprite,
and clicks registered offset from where the system cursor was drawn.

**Root cause.** `osdep_compat/win32_api.h` had `SetCursor`/`ShowCursor`/
`SetCursorPos`/`LoadCursorFromFile` as no-op inline stubs. The engine's
software-cursor mode calls `SetCursor(nullptr)` to hide the system cursor and
draw its own bitmap — no-op meant the system cursor stayed visible. Plus
`LoadCursorFromFile` returning `nullptr` made `DEBUG_ASSERTCRASH(cursorResources[…])`
fire and rest of the cursor pipeline silently bail.

**Fix.** Two files:
- `cmake/dx8_stub/metal_backend.{h,mm}` — added Cocoa helpers
  `MetalCursor_Show(int show)` (counter-based hide via `[NSCursor hide]`/
  `[NSCursor unhide]`) and `MetalCursor_WarpClient(int x, int y)`
  (content-view pixel → screen point via
  `convertRectToScreen` → flip Y → `CGWarpMouseCursorPosition`).
- `Dependencies/Utility/osdep_compat/win32_api.h` — wired
  `SetCursor` (nullptr → Hide, non-null → Show), `ShowCursor`,
  `SetCursorPos`. `LoadCursorFromFile` now returns `(HCURSOR)0x1`
  (dummy non-null) so the cursor-resources assert passes and the
  engine's setCursor logic actually runs.

System cursor now hides whenever the engine wants its software cursor; click
positions and software cursor stay in sync.

### Open issues (this session uncovered; tracked for next session)

1. **Menu button BGs render with tiled/striated content** — visible as
   horizontal "scanline" texture inside SOLO PLAY / MULTIPLAYER buttons in
   the main menu. User confirmed this has been present **since the Stage 2
   2D porting** (long-standing pre-existing bug, not a regression). Likely a
   2D-sprite UV or sampler-state issue in the texture-stage setup for the
   GameWindow button path. Cosmetic; low-priority.

2. **Persistent player-color rectangle near visible buildings in-game** —
   **★ FIXED (2026-05-24) — proper Metal stencil implementation, Stage 5.**
   Root cause was `DX8Wrapper::Has_Stencil()` returning `true` on macOS
   even though the Metal-shim originally ignored `D3DRS_STENCILENABLE`/
   STENCILFUNC/STENCILOP_* states. With stencil reported as available,
   `RTS3DScene::flushOccludedObjectsIntoStencil`
   ([W3DScene.cpp:862](GeneralsMD/Code/GameEngineDevice/Source/W3DDevice/GameClient/W3DScene.cpp:862))
   ran the "see your buildings through occluders" pass: tag each player's
   buildings with a stencil index, then call `renderStenciledPlayerColor()`
   (XYZRHW full-screen quad in player color, gated by stencil EQUAL). With
   no real stencil filtering, the EQUAL test effectively passed → giant
   player-coloured rectangle painted over the scene per visible player.
   **First defensive fix (then superseded):** `Has_Stencil()` returned
   `false` on `__APPLE__`. Side-effect: stencil shadow volumes and
   `m_enableBehindBuildingMarkers` auto-disabled too. **Proper fix
   landed same session:** the Metal backend now carries a real stencil
   pipeline — Depth32Float_Stencil8 attachment, per-frame stencil clear
   to 0, the depth-stencil state cache is rebuilt around a combined
   `DSKey` (z-test/write/func + stencilEnable/Func/Fail/ZFail/Pass +
   read/write masks) hashed with FNV-1a, MSL pipeline descriptor carries
   `stencilAttachmentPixelFormat`, full `D3DSTENCILOP_KEEP..DECR` →
   `MTLStencilOperation*` mapping, and every draw with `stencilEnable`
   gets a `setStencilReferenceValue:`. `Has_Stencil()` is back to honest
   on macOS. **Files:** `cmake/dx8_stub/metal_backend.{h,mm}` (+8
   stencil fields in `MetalDrawCall`, `MapStencilOp`, `DSKey`/`MakeDSHash`,
   rewritten `GetDepthState`, depth texture format change, stencil
   render-pass attachment, `setStencilReferenceValue:` plumb),
   `cmake/dx8_stub/dx8_device.cpp` (seed D3D8 stencil defaults in ctor +
   plumb 8 states in `FillCommon`), `Core/.../dx8wrapper.cpp`
   (`Has_Stencil()` honest; `GEN_NO_STENCIL=1` escape hatch).
   **Bonus features now active:** stencil shadow volumes
   (`W3DVolumetricShadow`) and `m_enableBehindBuildingMarkers` work too.
   **Bisect methodology (recorded for future):** added
   `GEN_NO_VIEWS`/`GEN_NO_INGAMEUI`/`GEN_NO_MOUSE_DRAW`/`GEN_NO_POSTDRAW`/
   `GEN_NO_TEXT_BEARING`/`GEN_NO_2DSCENE`/`GEN_NO_DRAWABLES` env-vars at
   each render-pass chokepoint in `W3DDisplay::draw` + `W3DView::draw` —
   only `GEN_NO_VIEWS=1` killed the artifact, which proved it was inside
   `W3DDisplay::m_3DScene->doRender()` but not in any per-drawable iter,
   pointing straight at the scene-level stencil-occlusion pass. Bisect
   env-vars are left in place for future use.

3. **Tooltip text shows only first character** — see fix #3 above. Core Text
   per-char widths are correct, but cumulative cursor state in
   `Render2DSentenceClass::Build_Sentence_Not_Centered` drops the rest of
   the string. Deeper than just font metrics — likely the
   `Allocate_New_Surface` / `Record_Sentence_Chunk` chunking logic on macOS.

### Suggested next-session approach

User proposed: **build a small isolated test scene** (one terrain plane +
one building + 2-3 lights) to repro the menu/in-game rectangle bug outside
gameplay. Easiest path:

- Extend `GEN_MODEL_VIEWER` (W3DDisplay.cpp:1808+) with optional ground
  plane geometry + a directional light + the existing camera, so
  `GEN_MODEL=UBCmdHQ` shows the building as it would appear in-game with
  shroud, lighting, and tooltip on hover. Then we have an offline repro.
- A/B with the existing menu (which exhibits the same bug pattern) —
  whatever fix works for the menu should fix the in-game rect.
- The tooltip-text-truncation likely shares root cause with the rectangle
  bug, so they may resolve together.

---

## ▶ Graphics quality scaling — Low → Medium / High / VeryHigh

**Status (2026-05-24):** the macOS port is now stable on `STATIC_GAME_LOD_LOW`
(after the stencil fix re-enables shadows + behind-building markers cleanly).
**Medium / High / VeryHigh** still glitch hard because each level flips
additional rendering features whose Metal-shim path is missing or broken.
The strategy from here on: enable one flag at a time, repro/diagnose each
artefact, fix the underlying shim or shader path, then move on. Do NOT
flip a whole preset and chase 10 bugs at once.

### What each preset actually does

`StaticGameLODInfo` ([GameLOD.h:100-127](GeneralsMD/Code/GameEngine/Include/Common/GameLOD.h:100))
is the per-level snapshot; `GameLODManager::applyStaticLODLevel`
([GameLOD.cpp:543-631](GeneralsMD/Code/GameEngine/Source/Common/GameLOD.cpp:543))
copies it into `TheWritableGlobalData` when the user picks a preset.
**The shipping `initStaticLODLevels()` only fills `STATIC_GAME_LOD_VERY_HIGH`;**
Low/Medium/High come from the on-disk `Data/INI/GameLOD.ini` (loaded via
`INI::parseLODPreset`, [GameLOD.cpp:181](GeneralsMD/Code/GameEngine/Source/Common/GameLOD.cpp:181)).
Defaults below are the engine's coded VeryHigh + commonly-observed
Generals retail INI values for the lower presets.

| Setting | Drives | Low | Medium | High | VeryHigh | macOS shim status |
|---|---|---|---|---|---|---|
| `m_useShadowVolumes` | Stencil shadow volumes (W3DVolumetricShadow): silhouettes projected from units/buildings | ✗ | ✗ | ✓ | ✓ | **NEEDS TEST** — Stage-5 stencil is wired up; this should now Just Work, but never exercised in-game |
| `m_useShadowDecals` | 2D blob/decal shadows under units (TexProject blob underneath everything) | ✓ | ✓ | ✓ | ✓ | **Needs verification** — uses `W3DShadowManager` + projected texture; on macOS the projection path through stage-1/2 multitexture may be partly stubbed |
| `m_useCloudMap` | Scrolling cloud-shadow noise pattern over terrain (`m_cloudMap` second texture stage on terrain) | ✗ | ✓ | ✓ | ✓ | **LIKELY BROKEN** — second TSS stage with scrolling UV transform; only stage 0 fully validated by the cliff-shroud TCI fix |
| `m_useLightMap` | Light-map noise pattern (`TSNoise...` textures) blended onto terrain to break tiling | ✗ | ✓ | ✓ | ✓ | **LIKELY BROKEN** — same multi-stage texture path as cloud map; needs TSS plumb verification |
| `m_showSoftWaterEdge` | Feathered shoreline blending (shoreline tile alpha-fade) — drives `TheTerrainVisual->setShoreLineDetail()` | ✗ | ✓ | ✓ | ✓ | **Unknown** — extra geometry pass, unsure if it goes through working FF path |
| `m_useBuildupScaffolds` (=`!m_useDrawModuleLOD`) | Construction scaffolds: rotating cranes / animated frames while a building goes up | ✗ | ✓ | ✓ | ✓ | **Should work** — pure W3D model + anim, same path as built models (which we proved with `GEN_MODEL_VIEWER`); test it |
| `m_useTreeSway` | Trees sway in wind (per-vertex CPU animation in `W3DTreeBuffer`) | ✗ | ✓ | ✓ | ✓ | **Should work** — CPU-side vertex update, no shader |
| `m_useEmissiveNightMaterials` | Second lighting pass on buildings for "glowing windows" at night | ✗ | ✗ | ✓ | ✓ | **Untested** — two-pass material; could hit FF combiner edge case |
| `m_useHeatEffects` | Heat-distortion shader (Microwave Tank, fire) — full-screen ripple via offscreen RT + sample | ✗ | ✗ | ✓ | ✓ | **BROKEN** — needs render-to-texture + a pixel-shader-equivalent post-effect that the FF shim doesn't have |
| `m_useTrees` | Trees rendered at all (vs barren map) | ✓ | ✓ | ✓ | ✓ | **Works** — verified in skirmish |
| `m_useFpsLimit` | 30 Hz frame-rate cap on (default) | ✓ | ✓ | ✓ | ✓ | Works — host pacing |
| `m_enableDynamicLOD` | Auto-degrade particle/debris density if FPS drops below preset thresholds | ✓ | ✓ | ✓ | ✓ | Works |
| `m_maxParticleCount` | Particle pool cap | 500 | 1500 | 2500 | 5000 | Works |
| `m_maxTankTrackEdges` | Tank track length (number of vertex segments) | 25 | 50 | 100 | 100 | Works |
| `m_maxTankTrackOpaqueEdges` | Length before fade starts | 10 | 15 | 25 | 25 | Works |
| `m_maxTankTrackFadeDelay` (ms) | How long a track segment stays visible | 60000 | 150000 | 300000 | 60000 | Works |
| `m_textureReduction` | Halve texture res N times (0..2). Driven by **video-RAM detection**, not the preset | 0..2 | 0..2 | 0..2 | 0..2 | Works — DDS load path stable since BC1/2/3 fix |
| `m_sampleCount2D/3D/m_streamCount` | Audio voice channel counts | 6/24/2 | … | … | … | Out of scope — audio path |

**Beyond `StaticGameLODInfo` — extra flags the options menu sets directly
(`OptionsMenu.cpp:438-471`, [OptionPreferences.cpp](Core/GameEngine/Source/Common/OptionPreferences.cpp)):**

| Setting | INI/pref key | Drives | macOS status |
|---|---|---|---|
| `TheGlobalData->m_waterType` | (engine-internal) | 0=translucent, 1=framebuffer-reflection, 2=PixelShader reflection (CnC water shader) | **Type 0 works; Type 1 LIKELY BROKEN** (needs render-to-texture for reflection); **Type 2 BROKEN** — needs HLSL pixel-shader port, not in FF shim |
| `TheGlobalData->m_enableBehindBuildingMarkers` | `BuildingOcclusion` | "see your buildings through enemy buildings" — gated on stencil + occlusion shader. NOW unblocked by the stencil fix | **NEEDS TEST** post-stencil-fix |
| `m_useShadowVolumes` (UI: 3DShadows) | `UseShadowVolumes` | Same as preset flag above | See preset row |
| `m_useShadowDecals` (UI: 2DShadows) | `UseShadowDecals` | Same | See preset row |
| `getAntiAliasing()` | `AntiAliasing` | `WW3D::MultiSampleModeEnum` (None/2x/4x/8x) → `MTLRenderPassDescriptor sampleCount` | **✅ Done (Stage 7)** — `cmake/dx8_stub/metal_backend.mm` allocates memoryless MSAA colour+depth and resolves into the drawable; env `MTL_MSAA=0/1/2/4/8` (default 4); unsupported counts auto-fallback. Engine option still ignored — wiring `getAntiAliasing()` → `MTL_MSAA` is one-line and trivial follow-up (not blocking; env override fine for now). |
| `getTextureFilterMode()` | `TextureFilterMode` | trilinear / anisotropic in MTLSamplerDescriptor | Partly — bilinear works (`magFilter/minFilter`), mipmap chains not yet validated |
| `getTextureAnisotropyLevel()` | `TextureAnisotropy` | Max anisotropy on sampler | Not plumbed in shim |
| `getDynamicLODEnabled` | `DynamicLOD` | Same as preset flag | Works |
| `getFPSLimitEnabled` | `FPSLimit` | Same | Works |

### Open questions before flipping any flag

1. **What does the user's current `Options.ini` actually have?** — need to read
   `~/Documents\…/Options.ini` to know which preset the game booted at and
   which individual flags were customized. (The path has literal backslashes
   in the directory name; this is a known separate Windows-pathism bug.)
2. **Does each flag cleanly toggle at runtime?** — some flags require shadow
   re-allocation (`TheGameClient->releaseShadows()/allocateShadows()`) which
   already happens in `applyStaticLODLevel`; others (texture reduction)
   re-LOD all textures.
3. **Heat effects + water Type 2** need pixel shaders. The shim is FF-only.
   Either we synthesize the equivalent via MSL fragment paths (DXVK-style),
   or we stub these features and treat them as "not supported on macOS port
   yet".

### Work plan — strict one-flag-at-a-time

Order picked by **(a) high visual impact, (b) low implementation cost on
Metal shim**:

1. **`m_useShadowVolumes`** — re-test now that stencil works. If silhouette
   shadows render correctly, that's a free unlock from the stencil fix.
2. **`m_useShadowDecals`** — projected-texture blob shadows. Test alone.
   If broken, diagnose `W3DShadowManager` + projection texgen path.
3. **`m_useCloudMap`** — terrain second-stage cloud overlay. Almost
   certainly hits the same `D3DTSS_TEXCOORDINDEX` / `D3DTS_TEXTURE0` plumb
   we fixed for shroud — likely a one-line stage-1 fix once we trace it.
4. **`m_useLightMap`** — sibling of cloud map; same TSS stage 1 territory.
5. **`m_useEmissiveNightMaterials`** — two-pass building lighting. Test.
6. **`m_showSoftWaterEdge`** — shoreline alpha-feather. Test.
7. **`m_useBuildupScaffolds`** + `m_useTreeSway` — should already work; tick
   them off the list cheaply by verifying.
8. ~~**`getAntiAliasing()` (MSAA)** — needs MSAA resolve in the Metal render
   pass + sampleCount in pipeline descriptors. Real but well-defined work.~~
   **✅ Done (Stage 7).** Memoryless 4x MSAA in `cmake/dx8_stub/metal_backend.mm`;
   env `MTL_MSAA=0/1/2/4/8` (default 4); device-cap fallback. Shadows
   verified working alongside. Only remaining engine touch is the one-line
   `getAntiAliasing()` → env-or-API wiring (not blocking).
9. **`m_waterType=1`** (framebuffer reflection) — needs render-to-texture
   support of the reflected scene; useful infrastructure for any future
   post-effect.
10. **`m_useHeatEffects` + `m_waterType=2`** — pixel shader equivalents.
    Largest effort. Defer until everything above is solid.

Each item: switch ONLY that flag in the user's Options.ini (or expose a
`GEN_FORCE_*=1` override), boot a skirmish, capture screenshot, classify
"works / glitches / crashes". Then fix or document and move on.

### Test harness suggestion

A new env-var family in `GameEngine::init` post-`DebugAutoStartSkirmish`:
- `GEN_FORCE_SHADOW_VOL=0/1` → sets `m_useShadowVolumes` after preset apply
- `GEN_FORCE_SHADOW_DECAL=0/1`
- `GEN_FORCE_CLOUDMAP=0/1`
- `GEN_FORCE_LIGHTMAP=0/1`
- `GEN_FORCE_HEAT=0/1`
- `GEN_FORCE_NIGHT_EMISSIVE=0/1`
- `GEN_FORCE_WATER_TYPE=0/1/2`
- `GEN_FORCE_AA=0/2/4/8`

Plus `GEN_GFX_PRESET=low|medium|high|veryhigh` to force `applyStaticLODLevel`
before any individual override fires. This way every A/B is a single
process-start with one env var change — no Options.ini editing each time.

---

## ▶ Terrain "black spots" — FIXED ✅ (D3DTSS_TEXCOORDINDEX + tex1)

After the water fixes, the user pointed out scattered dark spots on the
ground in the cratered-desert shellmap frames and on the Tournament Plains
gameplay map. They suggested: "the textures fill the ground algorithmically
and somewhere they're not flush." Exactly right.

**Root cause:** the FF terrain shader (`TerrainShader2Stage::set` in
`Core/.../W3DShaderManager.cpp`) renders terrain in **TWO PASSES**:

- Pass 0 — base terrain tiles. `D3DTSS_TEXCOORDINDEX=0` → use UV set 0.
- Pass 1 — **alpha-edge blend** that smooths transitions between adjacent
  terrain tile types (grass ↔ sand, dirt ↔ rock, etc.). It rebinds the
  same atlas texture and sets `D3DTSS_TEXCOORDINDEX=1` so it samples the
  alpha-edge sub-tiles from a DIFFERENT atlas position via the SECOND
  vertex UV set (`VertexFormatXYZDUV2` has TEX0 at offset 16, TEX1 at
  offset 24).

Our Metal shim only knew `tex0Offset` and read TEX0 unconditionally. So
pass-1 sampled the wrong atlas region — alpha-edge blends landed at the
WRONG tile coordinates, painting random sub-tile content (or near-black
empty atlas gutters) between adjacent terrain types. Visible as scattered
black/dark spots and rectangular dark patches between terrain blocks.

**Fix (`cmake/dx8_stub/`):**
1. `FvfLayout` now computes `tex1Offset = cursor + 8` when TEX2+ is set.
2. `MetalDrawCall` gains `tex1Offset` and `texCoordIndex` fields.
3. `GetPipeline` resolves the stage-0 UV byte offset as
   `(texCoordIndex == 1 && tex1Offset >= 0) ? tex1Offset : tex0Offset`,
   and folds the resolved offset into the pipeline-cache key so each
   TEXCOORDINDEX value gets its own MTLRenderPipelineState.
4. Populated from `m_tss[0][D3DTSS_TEXCOORDINDEX]` in `dx8_device.cpp`.

**Bonus:** also plumbed `D3DTSS_ADDRESSU/V` per-draw via a cached
`MTLSamplerState` table — terrain explicitly sets CLAMP via the
TerrainShader2Stage pass setup, our shim was hardcoded to WRAP. This
prevents future seams from bilinear filtering wrapping the 2048-wide
atlas. (CLAMP alone didn't fix the spots; the TEXCOORDINDEX fix did.)

**Verified:** shellmap cratered desert frames (0900/1200) and naval
scenes — clean uniform terrain, no dark spots. In-game skirmish on Alpine
Assault — clean rocky terrain, walls and units render correctly.

**Lesson (PLAYBOOK #10):** when a FF D3D8 game uses multi-pass terrain
blending, the shim must honor `D3DTSS_TEXCOORDINDEX` per draw — otherwise
the second pass samples the wrong UV set and you get exactly this class
of "tile-boundary" / "scattered spot" artifact. Same goes for any draw
that uses TEX2+ FVF with multiple UV sets (water uses 2 sets too — water
draws happened to use UV set 0 only, so they weren't affected, but a more
faithful shim should plumb the index everywhere).

---

## ▶ Cloud Shadows → "black squares" on terrain — DEFERRED ⏸️ (cloud/shroud TEXCOORDINDEX state-leak)

**Symptom.** With the **Cloud Shadows** graphics option ENABLED, scattered
sharp BLACK quads (diamond/parallelogram shapes, terrain-cell sized) appear on
the terrain — on open grass, away from objects. With Cloud Shadows OFF the
terrain is clean. Fog of war works correctly in BOTH states.

**Investigation (env-gated diagnostics, all in `MetalContext_Draw`):**
- `MTL_TESTCLEAR=1` (clear → blue): squares stayed **black**, not blue → they
  are real draws painting black, NOT holes / missing chunks showing clear color.
- `MTL_SKIP_MULTIPLY=1` (skip multiply-blend passes): skipping `src=DESTCOLOR,
  dst=ZERO` alone → squares REMAINED. Skipping ALSO `src=ZERO, dst=SRCCOLOR`
  → squares GONE **but fog of war also gone** → the squares live in the same
  multiply family as the shroud/fog overlay.
- `MTL_DRAWLOG=1` (one line per unique draw signature) showed the culprit
  passes are camera-space multiply passes; several arrive with **`tci=0`**
  (PASSTHRU) when they should be `tci=2` (CAMERASPACEPOSITION).
- `GEN_NO_SHROUD=1` (force all shroud cells = 255 white): squares STAYED black
  → NOT the shroud texel VALUES. A white shroud should multiply terrain by 1.0
  (no darkening); black squares persisting means the texgen samples the shroud
  texture's black BORDER (or a wrong texel), not the white interior.

**Root cause (confirmed).** Same class as the "Terrain black spots" fix above,
but for the **camera-space-position texgen** used by the cloud/noise/shroud
overlay passes. `ShroudTextureShader::set` and `TerrainShader2Stage::set(2)`
(the cloud/noise pass) both set `D3DTSS_TEXCOORDINDEX = TCI_CAMERASPACEPOSITION`
+ `D3DTTFF_COUNT2` + a `D3DTS_TEXTURE0/1` projection matrix, so the overlay
texture is projected onto terrain from each vertex's camera-space position.
Our shader handles this via the `tciActive` branch
(`tciMode==2 && texXformCount>=2 && posFloats==3` → `uv = texXform·view·world·pos`).
When Cloud Shadows is on, the extra cloud pass sets then **resets**
`TEXCOORDINDEX`, and a subsequent shroud/terrain draw reaches our backend with
`tciMode=0` (the engine's per-draw state at draw time was 0 — the shim tracks it
faithfully). The triple-gate then FAILS → the shader falls back to `uv = in.uv`
(raw terrain-atlas UVs) → the overlay samples a black atlas gutter / shroud
border → solid black quad. (The shim comment in `metal_backend.h` near `tciMode`
already documents the original "solid black quads on cliff peaks" instance of
this exact failure, fixed for the shroud-only case; cloud-on re-triggers it.)

**Why NOT a simple combiner / multitexture problem.** First hypothesis was a
missing 2nd texture stage (cloud=stage0, edge-mask=stage1). A full stage-1
multitexture combiner + DESTCOLOR blend was implemented and tested — it did
**not** fix the squares AND it degraded fog of war (stage-1 sampled with raw
UVs because the stage-1 `D3DTS_TEXTURE1` texgen was un-plumbed). That work was
**reverted** (`git checkout` of `dx8_device.cpp`, `metal_backend.h/.mm`). Do
NOT re-attempt the multitexture combiner without ALSO plumbing the stage-1
camera-space texgen — and even then the real bug is the `tci=0` state-leak, not
the combiner.

**Decision (2026-05-29).** Deferred. Cloud Shadows is optional eye-candy
(moving cloud shadows on terrain); everything else (fog of war, terrain, units)
is correct without it. User disables Cloud Shadows in Options → Graphics for
now. No code change landed (working tree reverted to the clean committed state).

**Path to fix when revisited:**
1. Reproduce with `MTL_DRAWLOG=1` + Cloud Shadows ON; confirm which exact pass
   signatures arrive with `tci=0` that should be `tci=2`.
2. Decide where to correct the state: either (a) make the shim re-derive
   CAMERASPACEPOSITION when a stage has `D3DTTFF_COUNT2` + a non-identity
   `D3DTS_TEXTURE{stage}` even if `TEXCOORDINDEX` low bits got reset to the
   stage number (heuristic), or (b) trace the engine's cloud→shroud pass
   ordering and ensure our `m_tss`/`m_transforms` snapshot per draw matches
   what D3D would have at that draw (faithful state tracking).
3. If pursuing correct cloud rendering, ALSO plumb the **stage-1** texture
   transform (`D3DTS_TEXTURE1`) + stage-1 `tciMode/texXformCount` into the
   uniforms and compute `o.uv1 = texXform1·view·world·pos` — the cloud/noise
   pass (`ST_TERRAIN_BASE_NOISE12`) uses camera-space texgen on BOTH stages.
   ⚠️ The `Uniforms` MSL/CPU structs have delicate padding for `lights[]`
   alignment — adding fields risks breaking ALL lighting; verify offsets.
4. Verify fog of war stays correct (it's the same multiply family — easy to
   regress).

**Diagnostic env vars used (left in tree only if still present; otherwise
re-add):** `MTL_TESTCLEAR`, `MTL_SKIP_MULTIPLY`, `MTL_DRAWLOG`, `GEN_NO_SHROUD`.

---

## ▶ Water depth-ordering (renders OVER occluders) — FIXED ✅

After the black-grid was killed (see next section), the user reported a second
issue: helicopters/ships flying ABOVE the water surface were rendering BENEATH
it — water painted over everything that should occlude it. `MTL_ZDUMP=1` (a
one-shot per-FVF depth-state dump in `MetalContext_Draw`) showed **ALL** FVFs —
0x012, 0x112, 0x142, 0x152, 0x242 (terrain), 0x252 (water) — had `zEn=0` (depth
test DISABLED). The 3D scene only looked vaguely right because submission order
happens to be roughly back-to-front; water (drawn last) ended up on top of
everything.

**Root cause:** `Core/.../WW3D2/dx8wrapper.cpp::Apply_Default_State()` is DEFINED
(sets ZENABLE=TRUE, ZWRITE=TRUE, ZFUNC=LESSEQUAL, etc.) but **never CALLED
anywhere in the source tree** (grepped). The per-draw `ShaderClass::Apply()` sets
`D3DRS_ZFUNC` and `D3DRS_ZWRITEENABLE` but **not `D3DRS_ZENABLE`** — it assumed
the D3D8 device default of `D3DZB_TRUE`. On Windows D3D8 hardware really did
default ZENABLE=TRUE when a depth buffer was present; the Metal shim zero-inits
its render-state array, so ZENABLE stayed 0 forever and *no draw ever depth-tested*.

**Fix:** `cmake/dx8_stub/dx8_device.cpp::MetalDevice8` constructor seeds
`m_renderStates[D3DRS_ZENABLE] = TRUE`. Only that one state — initially I seeded
the full D3D8 default block (ZWRITE/ZFUNC/CULLMODE/LIGHTING/blend etc.) but that
broke in-game rendering (caused a black blob over the camera-view; some shroud-
or terrain-related state read the seeded default and behaved differently from
the prior zero-init). Narrowing to ZENABLE only is the minimum-surface fix. Opt
out with `MTL_DEPTH_OFF=1` for A/B testing.

**Verified:**
- Shellmap frames 0360/0900/3000: ships floating ON water, helicopters above,
  bridges with vehicles, water correctly BENEATH foreground geometry.
- In-game `GEN_AUTO_SKIRMISH=1` frames 0600/1200/1800: Alpine Assault terrain,
  units, walls, HUD all render correctly — no regression.
- Menu UI (`SOLO PLAY`/`MULTIPLAYER`/etc.) composites correctly on top of the
  3D backdrop (2D path uses orthographic MVP that puts UI at NDC z~0, always
  passes LESSEQUAL).

**Lesson (PLAYBOOK #9):** When porting a D3D8 game, *don't trust the shim's
state-array zero-init*. D3D8's spec defaults for ZENABLE, ZWRITEENABLE, ZFUNC,
CULLMODE, LIGHTING etc. are *device-set on hardware*; engines that came up
through DX8 commonly rely on them and never explicitly write them. Seed the
specific defaults you find by symptom — but narrow the seed to one state at a
time and A/B test each, because seeding ones that DO get written per-draw in
some paths can perturb the order in subtle ways.

---

## ▶ Shellmap "black grid" water — FIXED ✅

**Root cause:** `WaterRenderObjClass::drawTrapezoidWater` (`Core/.../W3DWater.cpp`
~line 3398) does a **SECOND** trapezoid-water pass to apply the shroud over water
*specifically on the fallback branch where `m_trapezoidWaterPixelShader == 0`*. On
macOS that branch is always taken because we report `PixelShaderVersion=0` in
`MetalDevice8::GetDeviceCaps` (the PS-disable fix that lets all the other FF
fallbacks engage). The fallback pass rebinds the SHROUD TEXTURE at stage 0 and the
`W3DShaderManager::ST_SHROUD_TEXTURE` multi-stage shader, then re-draws the SAME
tessellated mesh. That multi-stage TSS chain (D3DTSS_COLORARG/ALPHAARG combinations
across multiple stages) is **not emulated in the Metal FF shim**, so the second
pass renders as near-opaque dark tiles over the (correct) first water pass — that's
the visible black grid.

**Why prior diagnostics misdirected:** `GEN_NO_SHROUD=1` only skipped the
*standalone* shroud render in `W3DShroud::render`, NOT the shroud-on-water second
pass living inside `drawTrapezoidWater`. `MTL_WATER_NOPASS2` (intended to skip the
blend-disabled water "pass 2") was matching the wrong draw set (river-water FVF
0x252 with `!blendEnable` doesn't exist for this case — both passes are blended).
The geometry probe (after Move 1's `g_inTrapWater` tagging) confirmed the trapezoid
mesh's verts/indices form a fully-continuous 37×40 grid with `(j*uCount+i)` layout,
sane stride/offsets, max-index = vertexCount-1: **geometry is correct.** Then
`GEN_WATER_SOLID=1` + `MTL_TESTCLEAR=1` (blue clear) showed the gaps still rendered
*black*, not blue — i.e. the gaps were *being drawn into*, not left uncovered. That
pinned the bug to a separate second draw, and a grep for `Draw_Triangles` inside
`W3DWater.cpp` immediately surfaced line 3399.

**Fix (`Core/.../W3DWater.cpp::drawTrapezoidWater`, around line 3383):** under
`#if defined(__APPLE__)`, skip the `if (TheTerrainRenderObject->getShroud()) ... else
{ /* fallback shroud-on-water pass */ }` branch by default. `GEN_WATER_SHROUD_PASS2=1`
opts back IN for A/B testing. Pure-Windows path untouched.

**Verified:**
- `/tmp/gen_frame_0600/0900/1200.png` (no env vars) now show clean translucent
  blue water with **ships visible underneath** (was: opaque black grid).
- `GEN_AUTO_SKIRMISH=1` regression run renders Alpine Assault terrain + HUD
  correctly through frame 1800+ (no regressions).

**Follow-ups (not blocking):**
- Shroud (fog-of-war) over water is now NOT applied on macOS. For the shellmap
  this is invisible (no fog-of-war in the menu backdrop). In gameplay it means
  the water surface itself doesn't darken in unexplored regions — terrain still
  darkens correctly. If/when we want shroud-over-water properly, implement
  `ST_SHROUD_TEXTURE` as a Metal multi-pass with the shroud sampled as a second
  stage; or do a simple grayscale-modulate using the shroud surface and the
  water's existing TEX1 set.
- Dashed/broken UI button borders (`Render2DClass`).
- 1 remaining `.tga` failure (`trstrtholecvr.tga`) — likely a genuinely-absent road decal.
- Gameplay QA per the user's direction (`GEN_AUTO_SKIRMISH=1`, dozer→CC→units,
  save/load round-trip).

### Debug infra still in tree (env-gated, zero cost when off)
- `GEN_NO_WATER=1` — skip all water (diagnostic only).
- `GEN_WATER_SOLID=1` — white diffuse + null stage-0 tex in drawTrapezoidWater /
  drawRiverWater / renderWaterMesh / setupFlatWaterShader. Exposes raw water geometry.
- `GEN_WATER_SHROUD_PASS2=1` — opt back IN to the broken fallback shroud-over-water
  pass (for A/B; **leaves the black grid back on**).
- `GEN_NO_SHROUD=1` — skip standalone shroud render in `W3DShroud::render`.
- `MTL_WATERGEOM=1` — dump first 4 trapezoid water draws' verts/indices via the
  engine-side `MetalDebug_InTrapezoidWater()` tag.
- `MTL_WATER_NOPASS2=1` — drop FVF 0x252 blend-disabled draws (no observed effect
  since the bug was elsewhere, but retained for future water diagnostics).
- `MTL_TESTCLEAR=1` — force blue clear color (decisive "covered vs uncovered" test).

---

## ▶ PLAYBOOK — debugging methodology (apply these by DEFAULT, every session)

These are the approaches that have actually cracked this port. Reach for them
*before* ad-hoc poking. They compound: most wins came from combining 2–3 of them.

**1. LP64 type-width is the #1 recurring root cause — suspect it FIRST on any
binary/parse/serialization bug.** macOS arm64 is **LP64**: `long`/`unsigned long`
= **8 bytes** (vs 4 on Win32), and `wchar_t` = **4 bytes** (vs 2 on Win32). Any
type whose *name promises a width* but is built on `long`/`wchar_t` silently
changes `sizeof` on macOS, so any `read(&s, sizeof(s))` / `memcpy` / pointer cast
desyncs binary streams. Confirmed instances (all the same disease): `uint32`/
`sint32` = `unsigned/signed long` in `bittype.h` (broke ALL W3D model loading —
units/buildings); `wchar_t`/`WideChar` 4-byte (broke CSF strings, LanguageFilter,
DataChunk unicode); `TGA2Footer`/`TGA2Extension` `long` fields (broke every TGA);
`D3DXGetFVFVertexSize`/`FVFInfoClass` `sizeof(DWORD)` (broke 2D vertex stride);
`WindowMsgData`=32-bit truncating 64-bit pointers; `persistfactory.h` pointer↔uint32.
**Fix pattern:** make the type its *true* fixed width (`unsigned int` for a 32-bit
field, read/write 16-bit + widen/narrow for `wchar_t`), guarded `#if defined(__APPLE__)`
— it's a **no-op on Win32** (where `long`==`int`==32-bit) so it never breaks Windows.
**Grep recipe to hunt more:** `grep -rn "sizeof(DWORD)\|sizeof(LONG)\|sizeof(uint32)\|(uint32)\|(DWORD)[^)]*ptr\|unsigned long" <area>` and audit every on-disk struct / `cload.Read` / `csave.Write` site. The symptom signature: a chunk/record id that decodes to a **float-looking hex** (e.g. `0x41800000` = `16.0f`) means the reader is mis-aligned and reading payload floats as headers.

**2. Build an ISOLATION HARNESS instead of debugging through the whole game.**
Driving the bug through menus/full-scene is slow (tokens + load time) and noisy.
Add a small env-gated entry point that exercises *one subsystem* directly:
`GEN_MODEL_VIEWER` (render one mesh — bisected the W3D-load bug in one run),
`GEN_AUTO_SKIRMISH` (boot straight into gameplay — no menu clicking),
`metal_smoketest` (renderer with no engine). When something "doesn't render/work",
the first question is *"does it load?"* not *"does it draw?"* — the model viewer
answered that instantly (`Create_Render_Obj -> 0x0`). **Make the harness env-gated
(`getenv`), `#if defined(__APPLE__)`, zero-cost when off, and leave it in the tree.**

**3. SEE what the game draws — `MTL_DUMP=1` → `/tmp/gen_frame_*.png` → `Read` it.**
There's no `screencapture` permission here. The Metal backend dumps its own drawable
to PNG at fixed frames (5/60/180/360/600/900/1200/1800/2400). This is the primary
visual oracle — always dump + Read frames rather than asking the user "what do you
see". A black/empty area + a non-null load = a *shading/material* problem; a missing
object = a *load* problem; garbage = a *desync*. (Gotcha already paid for: terrain
writes dest-alpha 0 → dumps looked white over a transparent bg though RGB was fine →
`layer.opaque=YES` + force alpha 255 in the dump.)

**4. Symbolicate crashes with `atos` against the Release binary — don't trust the
raw `.ips` symbol+offset.** Release strips/inlines, so the crash report's nearest-
symbol names are often wrong (huge `+offsets`). Recipe: pull `imageOffset`s from
`~/Library/Logs/DiagnosticReports/generalszh-*.ips` (it's two JSON docs: header line
+ body), then `atos -o build/apple-arm64/GeneralsMD/Release/generalszh -l 0x100000000
0x<100000000+offset>`. That turned a bogus "drawWaypoints+4464768" into the real
`W3DWaypointBuffer::drawWaypoints` null-deref. A null-deref at `0x0` in a render path
is almost always a `Create_Render_Obj`/asset that returned null and wasn't guarded.

**5. Verify asset *presence* before assuming an asset bug.** Binary-grep the BIGs:
`for f in *.big; do LC_ALL=C grep -al -i "<NAME>" "$f" && echo $f; done`. This is how
"SCMNode is missing" was disproved (it's in `W3D.big`) — which redirected the hunt
from "missing file" to "loader desync" (the real bittype bug). Also remember **ZH is
an expansion**: many base textures/models (`Art/Terrain/*`, lots of `W3D`) live only
in the BASE `Command and Conquer Generals/{Terrain,Textures,W3D}.big` — symlink those
3 (and ONLY those 3) into the ZH dir; symlinking INI/English/Audio collides & crashes.

**6. Use `cix` for semantic/where-is questions, `grep` only for exact strings.**
`cix search "<concept>"`, `cix def <Symbol>`, `cix refs <Symbol>` beat grep for
"where is X set up / how does Y work / who calls Z". Grep is for exact error strings,
config keys, enum values. (`cix` found `Matrix3D::Look_At` and the skirmish-start path
fast.)

**7. Keep the Windows build sacred + don't commit.** Every fix is `#if defined(__APPLE__)`
or a provably-no-op-on-Win32 correctness fix (LP64 width fixes qualify). Never
`git commit/add/push` unless asked. Never touch `~/vcpkg` or `build/.../_deps/`.

**8. Record root causes in this file the moment they're found** (Progress Tracker
row + the relevant Stage's "completed work"), with the *real* mechanism, the file:line,
and the fix — so the next session starts from truth. Update the tracker LAST.

---

## ▶ DEBUG TOOLING — self-capture frames to PNG (no screenshot permission needed)

This environment has **no `screencapture` permission** ("could not create image
from display"). Instead the Metal backend can dump its own rendered drawable to
PNG so the agent can `Read` the image and see exactly what the game draws. **This
is the primary visual-debug loop — use it instead of asking the user "what do you
see".**

**How (all in `cmake/dx8_stub/metal_backend.mm`, gated by env vars, off by default):**
- `MTL_DUMP=1` → at frames 5/30/90 and every 240, `MetalContext_Present` blits
  the drawable into a shared `MTLTexture`, reads it back, swaps BGRA→RGBA, and
  writes `/tmp/gen_frame_%04ld.png` via `NSBitmapImageRep` (AppKit, already
  linked). Requires `layer.framebufferOnly = NO`, which `MTL_DUMP` also sets.
- `MTL_DUMPTEX=1` (+ optional `MTL_DUMP_ALPHA=1`) → dumps every uploaded texture
  to `/tmp/gen_tex_NN_<ptr>_WxH.png`, the glyph DIBs from `gdi_text.mm` to
  `/tmp/gdi_dib_*`, and `CopyRects` source surfaces to `/tmp/copyrect_src_*`. With
  `MTL_DUMP_ALPHA` it writes the alpha channel as luminance (needed to SEE font
  atlases, which are white-RGB + coverage-in-alpha). Kept separate from `MTL_DUMP`
  so the frame-capture loop stays lightweight. This combo is how the
  scrambled-text / mirror bugs were pinned to specific stages.
- `MTL_TESTCLEAR=1` → forces the render-pass clear to **blue** (in `EnsureEncoder`),
  ignoring the game's clear color. Decisive present/window-vs-content test: blue
  window ⇒ present+window work, problem is content; black ⇒ present/window broken.
- `MTL_DEBUG=1` → existing gated instrumentation. Tags on stderr:
  `[clear]` clear color, `[dev]` per-present draw/skip counts + texture binding
  (real/missing/none), `[metal]` per-frame draw counts, `[tex]` texture
  UnlockRect (fmt + center BGRA), `[sss]` SetStreamSource, `[draw]` per-draw
  fvf/stride/texture, `[gdi]` glyph coverage (gdi_text.mm), `[surf->tex]`
  CopyRects→texture flush alpha, `[geom30]` per-draw **NDC bounding box** +
  diffuse color + uv + blend state for frame 30 (the richest 2D-geometry probe).

**Run loop:**
```bash
pkill -f generalszh; rm -f /tmp/gen_frame_*.png
cd "original/Command_and_Conquer_ZERO_HOUR_ORIGINAL/Command and Conquer Generals Zero Hour"
( MTL_DUMP=1 MTL_DEBUG=1 "$ABIN" >/tmp/run.log 2>&1 & echo $! >/tmp/gpid )
sleep 12; kill $(cat /tmp/gpid)
# then Read /tmp/gen_frame_0240.png and grep /tmp/run.log for the tags above
```
**Gotcha:** the Bash tool's cwd persists — after `cd`-ing into the asset dir to
run, `cd /Users/dvcdsys/Cursor/GeneralsGameCode` before building or the relative
`build/apple-arm64` path won't resolve.

**Keep these hooks** (they're env-gated, zero cost when off). The `[geom30]` /
frame-dump combo is what to reach for first on any "screen looks wrong" report.

### `GEN_AUTO_SKIRMISH` — boot straight into a 1v1 skirmish (no menu clicks)

`GEN_AUTO_SKIRMISH=1` makes the engine skip the shell menus and start a
**1 human + 1 easy-AI** skirmish immediately on launch. This is the primary
**in-game** debug loop — reproducing a gameplay/render bug by clicking through
SOLO PLAY → SKIRMISH → map → START every run is slow and expensive; this lands you
in-game in one step. Optional `GEN_AUTO_MAP="Maps\\Foo\\Foo.map"` overrides the map
(defaults to the preferred/`getDefaultMap(TRUE)` multiplayer map — currently
`Alpine Assault`). Combine with `MTL_DUMP=1` to capture in-game frames.

- **Implementation:** `DebugAutoStartSkirmish(const char*)` in
  `GeneralsMD/.../Menus/SkirmishGameOptionsMenu.cpp` (declared in
  `GameClient/GUICallbacks.h`) mirrors the **non-GUI** parts of
  `SkirmishGameOptionsMenuInit()` + `reallyDoStart()`: builds `TheSkirmishGameInfo`
  (slot0 = human from `SkirmishPreferences`, slot1 = `SLOT_EASY_AI`), picks/validates
  the map, `adjustSlotsForMap()`, `startGame(0)`, then posts `MSG_NEW_GAME`/`GAME_SKIRMISH`.
  Start positions/colors/factions are left random — the engine's
  `populateRandomStartPosition`/`populateRandomSideAndColor` fill them at game start.
- **Call site:** `GameEngine::init()` (`GeneralsMD/.../Common/GameEngine.cpp`), in an
  `#if defined(__APPLE__)` block right after the existing `m_initialFile` handling;
  it also forces `m_shellMapOn=FALSE`/`m_playIntro=FALSE`. Windows build untouched.
- **Run loop:**
  ```bash
  cd "original/Command_and_Conquer_ZERO_HOUR_ORIGINAL/Command and Conquer Generals Zero Hour"
  GEN_AUTO_SKIRMISH=1 MTL_DUMP=1 "$ABIN" >/tmp/run.log 2>&1 &
  # macOS has no `timeout`; kill via a background sleep: ( sleep 90; kill -9 $! ) &
  # then Read /tmp/gen_frame_0900.png etc. Frame dumps fire at 5/60/180/360/600/900/1200/1800/2400.
  ```

### `GEN_MODEL_VIEWER` — render ONE W3D model in isolation (bisect the mesh path)

`GEN_MODEL_VIEWER=1` (optional `GEN_MODEL=<name>`, default `ABBarracks_AC`) makes
`W3DDisplay::draw()` (`GeneralsMD/.../W3DDisplay.cpp`, early `#if defined(__APPLE__)`
return) render exactly one render object through a synthetic `SimpleSceneClass` +
`CameraClass`, bypassing the entire in-game scene/camera/culling/LOD machinery.
This is the **isolation harness** — it answers "does the mesh even load, and does
the raw mesh→`DrawIndexedPrimitive`→Metal path work?" without any in-game noise.
It logs `[modelviewer]` lines: the `Create_Render_Obj` result pointer, the bounding
sphere, and `numPolys`. **This is exactly how the `bittype.h` uint32 bug was found**
(viewer showed `Create_Render_Obj(...) -> 0x0` → the bug was *loading*, not drawing).
Combine with `MTL_DUMP=1` to see the model on screen. Caveat: the synthetic scene
has **no lights**, so a loaded mesh shows as a black silhouette — that proves
geometry/depth/raster, not shading. Model names are the `.w3d` filename stem
(`Art\W3D\<name>.W3D` inside `W3D.big`/`W3DZH.big`).

---

## ▶ NEXT SESSION — Stage 4 polish (texture/material on 3D models) → then gameplay QA

**The big Stage-4 blockers are cleared:** FF 3D renderer, depth/cull/lighting, shell-map
backdrop, W3D model loading (`bittype.h`), AND **textures** (the `ddsfile.h` void* LP64
fix + native BC) all work — **units, buildings and vehicles render fully skinned in a
live skirmish** (use `GEN_AUTO_SKIRMISH=1 MTL_DUMP=1` and Read `/tmp/gen_frame_0900.png`).
What remains is shroud + minor UI polish, then gameplay QA:

1. **★ PIXEL SHADERS DISABLED (big architectural fix — landed this session).** The Metal
   shim only emulates the D3D8 **fixed-function** pipeline; `SetPixelShader` is a no-op. But
   `GetDeviceCaps` advertised `PixelShaderVersion=ps_1_1`, so `W3DShaderManager::getChipset()`
   returned `DC_GENERIC_PIXEL_SHADER_1_1` and the engine built pixel-shader render paths
   (water, terrain cloud/noise, roads, FX) whose shaders the shim silently dropped → broken
   output (notably the shellmap **water**). Fix: `cmake/dx8_stub/dx8_device.cpp`
   `GetDeviceCaps` now reports `PixelShaderVersion=0` → engine uses its FF fallbacks (the
   game shipped them for GeForce2/TNT-class cards), which the shim does emulate. Verified:
   in-game skirmish still renders correctly (terrain/units/HUD), no regression.
2. **Shellmap "black grid" = the WATER** (NOT shroud — confirmed via `GEN_NO_SHROUD` left it,
   `GEN_NO_WATER` removed it, showing perfect desert terrain + buildings + crater). Deeply
   investigated this session; here is the **ground truth so the next session doesn't re-derive
   it**:
   - It's `WATER_TYPE_0_TRANSLUCENT`, FF path (`trapezoidPS=0` after the PS fix), tex
     `TWWater01`(`.dds`), `waterDiffuse=0xffb9b9b9` (tod=2). `GEN_WATER_SOLID` (forces opaque
     white + null stage-0 tex) per-call **color-cycling** proved the visible tiles are ONE
     `drawTrapezoidWater` call (uniform color, not many polygons).
   - **The water GEOMETRY is CONTINUOUS — there are NO gaps.** The shim-side vertex probe
     (`MTL_WATERGEOM=1`, dumps verts/indices for fvf `0x252`=`DX8_FVF_XYZNDUV2`) shows
     10×10-unit cells that abut exactly (e.g. cell A y∈[430,440], cell B y∈[440,450] share the
     y=440 edge with identical coords — no T-junction, no gap), indices `0 2 3 0 1 2 …` fully
     cover each quad. So the black grid is **NOT geometry and NOT texture** (gaps persist with
     the texture nulled + opaque white).
   - The probe showed **two water passes**: pass-1 `blend=1(SRCALPHA,INVSRCALPHA) zEnable=0
     zWrite=0`, pass-2 `blend=0(disabled) zEnable=0 zWrite=1`. **Ruled out this session:**
     z-fighting (neither pass tests depth); pass-2 (skipping `fvf==0x252 && !blendEnable` via
     `MTL_WATER_NOPASS2` left the grid unchanged → the grid is the **alpha-blended pass-1**).
   - **Important caveat for next session:** the `MTL_WATERGEOM` probe showed *continuous*
     4-verts-per-quad cells, but that layout is **river water (`drawRiverWater`)**, not
     `drawTrapezoidWater` (which builds a *shared-grid* tessellation: verts `j*uCount+i`). The
     `GEN_WATER_SOLID` color-cycle proved the visible grid tiles come from **`drawTrapezoidWater`**
     (uniform color = one call). So the probe analyzed the WRONG draw — `drawTrapezoidWater`'s
     actual shim geometry is still **unverified**, and its shared-grid tessellation over a
     DynamicVB/DynamicIB is the prime suspect for the gaps (e.g. the dynamic IB/VB offset or the
     `Draw_Triangles(start,polyCount,minVtx,vtxCount)` → DrawIndexedPrimitive mapping for this
     specific call). **Next concrete step:** make `MTL_WATERGEOM` distinguish the trapezoid draw
     (tag it engine-side, or dump only draws whose indices show the shared-grid pattern) and dump
     ITS verts/indices to see if THEY have gaps; if geometry is fine, the gap is in the shim's
     dynamic-buffer draw for that call. The "nice" reflective water needs the PS path we can't
     run — a dedicated Metal water shader is the longer-term answer.
   - **Debug infra left in tree (all Apple+env, zero cost):** `GEN_NO_WATER`
     (`W3DWater.cpp WaterRenderObjClass::Render`), `GEN_NO_SHROUD` (`W3DShroud.cpp render`),
     `GEN_WATER_SOLID` (opaque-white + null tex in `drawTrapezoidWater`/`drawRiverWater`/
     `renderWaterMesh` + `setupFlatWaterShader`), one-shot `[water]` line under `MTL_DEBUG`,
     and `MTL_WATERGEOM` (vertex/index dump for fvf 0x252 after frame 500) in
     `cmake/dx8_stub/metal_backend.mm`.
3. **Dashed/broken UI button borders.** The blue frame lines around menu buttons render
   as a dashed/stippled line instead of solid. Likely a 2D line-draw (`Render2DClass`
   line primitive) or a 1-px border texture sampled with the wrong addressing/filter.
4. **Then gameplay QA** (the user's stated direction): drive `GEN_AUTO_SKIRMISH`, then
   script actions (build a dozer → command center → units) and confirm the sim + render
   stay correct. Consider a save/load round-trip (watch the `persistfactory` 32-bit
   token + any other LP64 serialization — see PLAYBOOK #1).

**Texture-path files changed this session (all `#if`-free correctness or Apple-only):**
`GeneralsMD/.../WW3D2/ddsfile.h` (`void* Surface`→`unsigned Surface`, the essential fix);
`cmake/dx8_stub/dx8_device.cpp` (`CheckDeviceFormat` accepts DXT; `MetalTexture8`/
`MetalSurface8` compressed BC path; BC layout helpers); `cmake/dx8_stub/metal_backend.{h,mm}`
(`MetalContext_CreateTextureFmt` for BC1/2/3, `MetalContext_UploadTextureRaw`).

The historical Stage-2/Stage-4 build-up notes are kept below for reference.

### Working-tree state — files changed THIS session (all UNCOMMITTED, on `macos-port-phase1`)
The W3D-model-loading breakthrough + debug harnesses + crash fix touched exactly these
(verify with `git status --short`; the long list of GUI `.cpp` "M" entries is from
*earlier* sessions, not these changes):
- **`Core/Libraries/Source/WWVegas/WWLib/bittype.h`** — ★ the fix: `__APPLE__` branch
  `uint32`/`sint32` → `unsigned/signed int` (true 32-bit). Unblocked ALL W3D model loading.
- **`Core/Libraries/Source/WWVegas/WWSaveLoad/persistfactory.h`** — knock-on: Save/Load
  round-trip the object-pointer id as a 32-bit token via `uintptr_t` (was relying on
  `uint32`==8 bytes). Compile + save/load symmetry fix.
- **`GeneralsMD/.../W3DDevice/GameClient/W3dWaypointBuffer.cpp`** — 6 `if(m_waypointNodeRobj)`
  null-guards (crash fix; SCMNode load-fail → null deref).
- **`GeneralsMD/.../W3DDevice/GameClient/W3DDisplay.cpp`** — `GEN_MODEL_VIEWER` harness
  in `draw()` + 5 Apple-guarded includes (camera/assetmgr/rendobj/matrix3d/sphere).
- **`GeneralsMD/.../Common/GameEngine.cpp`** — `GEN_AUTO_SKIRMISH` call site (Apple-guarded
  block after the `m_initialFile` handling).
- **`GeneralsMD/.../Menus/SkirmishGameOptionsMenu.cpp`** — `DebugAutoStartSkirmish()` impl.
- **`GeneralsMD/.../Include/GameClient/GUICallbacks.h`** — its declaration.

Build: `cd /Users/dvcdsys/Cursor/GeneralsGameCode && cmake --build build/apple-arm64
--target z_generals --config Release -j8` (bittype.h is foundational → first build after
that edit recompiles a lot; subsequent ones are incremental). Build from the **repo root**;
run from the **asset dir** (Bash cwd persists — see PLAYBOOK / DEBUG TOOLING). Env setup
already in place: base-Generals `Terrain.big`/`Textures.big`/`W3D.big` are symlinked into
the ZH asset dir (needed for terrain + many models).

Quick re-verify after compact:
```bash
cd "original/.../Command and Conquer Generals Zero Hour"
GEN_AUTO_SKIRMISH=1 MTL_DUMP=1 "$ABIN" >/tmp/run.log 2>&1 &  ( sleep 70; kill -9 $! ) &
# Read /tmp/gen_frame_0900.png  → units/buildings/vehicles on the battlefield
grep -c "Old format mesh" /tmp/run.log   # must be 0
```

### Stage 2 text — completed work (Core Text), for reference
**Done & verified.** GDI glyph rasterization is backed by Core Text + Core Graphics.

**Why it had been blocked:** the engine rasterizes glyphs through Win32 GDI calls that were no-op `inline` stubs on macOS, so glyph bitmaps came back empty → no text.

### Exactly how the engine builds text (already traced)
- Glyph atlas builder: `Core/Libraries/Source/WWVegas/WW3D2/render2dsentence.cpp`, class **`FontCharsClass`**.
  - `FontCharsClass::Create_GDI_Font()` (~line 1476): `GetDC` → `CreateFont(height<0 = -pixels, width, …, ANTIALIASED_QUALITY, name)` → `CreateDIBSection` of a **24bpp BI_RGB top-down** DIB, `biWidth = PointSize*2`, `biHeight = -(PointSize*2)`, bits pointer returned in `GDIBitmapBits` → `CreateCompatibleDC` → `SelectObject(MemDC, bitmap)` + `SelectObject(MemDC, font)` → `SetBkColor(RGB(0,0,0))`, `SetTextColor(RGB(255,255,255))` → `GetTextMetrics` (needs `tmHeight`, `tmAscent`, `tmOverhang`).
  - `FontCharsClass::Store_GDI_Char(WCHAR ch)` (~line 1314): `ExtTextOutW(MemDC, xOrigin, 0, ETO_OPAQUE, &rect{0,0,w,h}, &ch, 1, NULL)` draws one glyph white-on-black into the DIB, then `GetTextExtentPoint32W(MemDC, &ch, 1, &size)` for advance width. It then reads coverage as **`GDIBitmapBits[index]` with `index += 3` per column and `stride = (((width*3)+3) & ~3)` per row** (i.e. 24bpp, takes the low byte of each pixel; white text → 0..255 coverage).

### The GDI surface to implement (currently no-op stubs)
File: `Dependencies/Utility/osdep_compat/win32_api.h` (~lines 1201-1223). These are `inline` returning null/empty. Replace with **real declarations** backed by a new Objective-C++ file `cmake/dx8_stub/gdi_text.mm` (or a Utility `.mm`) using **Core Text + CoreGraphics**:
- `HDC GetDC(HWND)`, `int ReleaseDC(HWND,HDC)`, `HDC CreateCompatibleDC(HDC)`, `BOOL DeleteDC(HDC)` — make `HDC` an opaque pointer to a small struct {bound bitmap, bound font, bk/text color}.
- `HFONT CreateFont(height,width,…,weight,italic,…,quality,pitch,name)` — build a `CTFontRef` from name+pixel size (`height<0` ⇒ `-height` px em), weight (FW_BOLD), italic. Map `"Generals"`→`"Arial"` is done by the caller. Game ships TTFs at the asset root (e.g. `BNKGOTHM.TTF`) — Arial exists on macOS so `CTFontCreateWithName` is fine to start.
- `HBITMAP CreateDIBSection(HDC,BITMAPINFO*,UINT,void** bits,…)` — allocate `abs(biHeight)*stride` bytes (24bpp, stride 4-aligned), hand back `*bits`; remember dims/stride in the HBITMAP struct.
- `HGDIOBJ SelectObject(HDC,HGDIOBJ)` — bind font or bitmap to the DC; return previous.
- `COLORREF SetTextColor/SetBkColor(HDC,COLORREF)` — store on the DC.
- `int GetTextMetrics(HDC,TEXTMETRIC*)` — fill `tmHeight = ascent+descent`, `tmAscent`, `tmOverhang=0` from the CTFont metrics.
- `BOOL ExtTextOutW(HDC,int x,int y,UINT,const RECT*,const WCHAR* s,UINT n,const int*)` — wrap the DC's DIB bits in a `CGBitmapContext` (24bpp won't work directly for CG — render into a temp **8-bit gray** or **RGBA** CGBitmapContext sized to the DIB, fill bkColor, draw the glyph(s) with `CTLineDraw`/`CTFontDrawGlyphs` at baseline `y + tmAscent` in white, then copy coverage into the 24bpp DIB writing the same byte to all 3 channels). Mind Core Graphics' bottom-left origin vs the DIB's top-down rows (flip).
- `DWORD GetTextExtentPoint32W(HDC,const WCHAR*,int,SIZE*)` — `CTLineGetTypographicBounds` / sum of advances → `cx`; `cy = tmHeight`.
- `BOOL DeleteObject(HGDIOBJ)` — free font/bitmap.

### Gotchas
- DIB is **24bpp top-down**; Core Graphics has no 24bpp context — render into an 8-bit (`kCGImageAlphaOnly`) or 32-bit context then expand to the 24bpp DIB.
- Baseline: GDI `ExtTextOut` y is the **top** of the cell; Core Text draws from the **baseline** → offset by `tmAscent`. Flip Y because CG is bottom-up.
- Keep it Apple-guarded; don't change the Windows path. Wire the new `.mm` into `cmake/dx8.cmake` (the `d3d8` target already links the Metal/AppKit frameworks; add CoreText/CoreGraphics, or reuse `apple_frameworks`).
- Verify with a string like the main-menu buttons; `Render2DSentenceClass::Build_Sentence_*` then draws the glyph quads through the **already-working** 2D Metal path.

### Current working-tree state the next session inherits (NOT committed)
- Stages 1, 2-core, 3 all done & verified. Build clean: `cmake --build build/apple-arm64 --target d3d8 --config Release` then `--target z_generals` (build `d3d8` first — a stale `libd3d8.a` is a known trap; check its timestamp).
- Run: from the asset dir `original/Command_and_Conquer_ZERO_HOUR_ORIGINAL/Command and Conquer Generals Zero Hour/`. `MTL_DEBUG=1` env enables gated renderer/input instrumentation (`[tex] [draw] [dev] [clear] [sss] [metal]` lines on stderr) — off by default. No `screencapture` permission in this environment; rely on the user for visual confirmation.
- The game boots to the main-menu **shell**, runs a stable frame loop, renders real UI textures + **text** via Metal, and responds to mouse/keyboard. The menu background is still **black** until Stage 4 (the 3D shell backdrop); 2D widgets + labels draw on top.
- Text files (this work): NEW `cmake/dx8_stub/gdi_text.mm` (Core Text/CoreGraphics GDI backend), added to the `d3d8` target in `cmake/dx8.cmake`; `cmake/apple.cmake` adds `-framework CoreText -framework CoreGraphics`; `Dependencies/Utility/osdep_compat/win32_api.h` — the font-rasterization GDI subset is now `extern` on Apple (real impl in gdi_text.mm), the rest stay inline stubs.
- Earlier files (Stages 2-core/3): `cmake/dx8_stub/metal_backend.{h,mm}` (draw path + input), `cmake/dx8_stub/dx8_device.cpp` (draw/texture/format), `Core/GameEngineDevice/{Include,Source}/Win32Device/GameClient/CocoaKeyboard.{h,cpp}` (added to `Core/GameEngineDevice/CMakeLists.txt`). Edits: `Win32GameEngine.cpp` (Apple mouse pump), `W3DGameClient.h` (Apple keyboard factory), `TARGA.h` (`long`→`int32_t` + static_asserts), `missingtexture.cpp` (transparent on Apple), `dx8_stub.cpp` (`D3DXGetFVFVertexSize`).

---

## 0. READ FIRST — universal briefing for every agent

You are porting a **Windows / DirectX 8** C++ game engine (≈1M LOC, circa 2002) to native macOS arm64. Read this whole section before touching anything.

### Hard constraints (NEVER violate)
- **🔒 SHIM-ONLY RULE (as of 2026-05-24).** All new rendering / graphics work
  goes **exclusively into `cmake/dx8_stub/`** (the D3D8→Metal shim). Game
  engine code is **off-limits** — no edits to `GeneralsMD/Code/`,
  `Generals/Code/`, or `Core/GameEngine*/`, even guarded with
  `#if defined(__APPLE__)`. Rationale: the engine must stay a clean
  Windows/DX8 codebase; **all** macOS-specific behaviour belongs in the
  translation layer. Whatever feature seems to "need" engine cooperation
  (shadow mapping needs scene-from-light, water reflection needs RT
  setup, …) is to be implemented by the shim observing D3D8 state +
  capturing/replaying draw calls, **not** by hooking the engine.
  *Exception:* the `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.{cpp,h}`
  file straddles the engine/shim boundary (it's the engine's D3D8 wrapper);
  a tiny `__APPLE__` patch there is tolerated when it's structurally a
  *cap-query / `Has_*()`* override, but new draw-time logic belongs in the
  shim. Earlier engine edits (`Drawable.cpp`, `HeightMap.cpp`,
  `WorldHeightMap.cpp`, `W3DModelDraw.cpp`, `W3DDisplay.cpp` model-viewer
  / drawFillRect clamp, `render2dsentence.cpp` font clamp,
  `GameEngine.cpp` `GEN_AUTO_SKIRMISH`/`GEN_FORCE_*` harness) are
  grandfathered in — **don't extend them, don't add new ones**.
- **Only modify files inside the repo** `/Users/dvcdsys/Cursor/GeneralsGameCode`. NEVER install system packages, NEVER edit `~/vcpkg`, NEVER edit anything under `build/apple-arm64/_deps/` (those are fetched dependencies — changes get wiped; shim around them in project code).
- **Do NOT `git commit` / `git push` / `git add`** unless the user explicitly says so. Leave changes in the working tree.
- **Never break the Windows / MSVC / MinGW build.** Guard new code with `#ifndef _WIN32` / `#if defined(__APPLE__)`. Pure-correctness fixes valid on all platforms (e.g. casting a pointer through `uintptr_t` before narrowing) may be unguarded.
- This is **macOS-only, Zero Hour-only** scope. The `apple-arm64` preset sets `RTS_BUILD_GENERALS=OFF`, `RTS_BUILD_ZEROHOUR=ON`, `RTS_BUILD_CORE_TOOLS=OFF`, `RTS_CRASHDUMP_ENABLE=OFF`.

### Build & run
```bash
cd /Users/dvcdsys/Cursor/GeneralsGameCode
export VCPKG_ROOT=~/vcpkg
cmake --preset apple-arm64                                   # only after editing a CMake file
cmake --build build/apple-arm64 --config Release -j8 -- -k 0 # -k 0 = keep going past errors
```
- Compiler: Apple clang, arm64, deployment target 12.0. Generator: Ninja Multi-Config.
- A failing **precompiled header** (`cmake_pch.hxx.pch`) blocks its WHOLE target → fix PCH errors first.
- Triage: `grep -E "error:|FAILED:" /tmp/build.log | head -50`. Count distinct failing files:
  `grep -E "error:" /tmp/build.log | grep -oE "[A-Za-z0-9_/.-]+\.(cpp|c):[0-9]+" | sed -E 's/:[0-9]+$//' | sort -u`.
- The game executable: `build/apple-arm64/GeneralsMD/Release/generalszh` (Mach-O arm64).
- **Game assets** (the user's licensed copy) live at:
  `original/Command_and_Conquer_ZERO_HOUR_ORIGINAL/Command and Conquer Generals Zero Hour/`
  (contains the `*.big` archives + a loose `Data/` dir). Run the game *from that directory* so it finds its data:
  ```bash
  ABIN="$(pwd)/build/apple-arm64/GeneralsMD/Release/generalszh"
  cd "original/Command_and_Conquer_ZERO_HOUR_ORIGINAL/Command and Conquer Generals Zero Hour"
  "$ABIN"
  ```

### Architecture you must know
- **Single graphics chokepoint:** every rendering call funnels through `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.{h,cpp}` (`DX8Wrapper`). It holds `static IDirect3D8* D3DInterface` and `static IDirect3DDevice8* D3DDevice` and calls them via the `DX8CALL(...)` macros. **Do not rewrite DX8Wrapper** — implement the D3D8 interfaces behind it.
- **The D3D8→Metal backend** lives in `cmake/dx8_stub/` (Apple-only, built into a CMake target named `d3d8` via `cmake/dx8.cmake`). `Direct3DCreate8()` returns a real Metal-backed `IDirect3D8`. Files: `metal_backend.{h,mm}` (Cocoa/Metal window+device), `dx8_device.cpp` (COM subclasses `MetalDirect3D8`/`MetalDevice8`/`MetalTexture8`/`MetalSurface8`/`MetalVertexBuffer8`/`MetalIndexBuffer8`), `metal_smoketest.cpp` (standalone test exe). The D3D8 interface vtables are declared in `build/apple-arm64/_deps/dx8-src/d3d8.h` — your Metal subclasses must match them method-for-method (it's a COM vtable; order matters).
- **The Win32 compatibility layer** is `Dependencies/Utility/osdep_compat/` — it's on the include path for non-Windows builds via the `core_config` INTERFACE target (see `cmake/config-build.cmake`, UNIX block). Key files:
  - `windows.h` — Win32 *type* vocabulary (DWORD, HANDLE, HRESULT, RECT, GUID, GDI structs, `__int64`, etc.); does NOT define `_WIN32`; includes `win32_api.h` + `winreg.h` at the end.
  - `win32_api.h` — **header-only POSIX-backed Win32 API** (file IO, GlobalAlloc/heap, QueryPerformanceCounter→mach_absolute_time, events/threads/mutex→pthread, dlopen→LoadLibrary, FindFirstFile→opendir, MessageBox→stderr, cursor/window/GDI stubs, locale/date stubs, `__min`/`__max`, etc.). **Extend HERE** for any new Win32 API — keep it header-only/inline so no CMake/link changes.
  - `winreg.h` — file-backed registry under `~/Library/Application Support/CommandAndConquerGenerals/registry/`.
  - `objbase.h` — COM macros (STDMETHOD, DEFINE_GUID, IUnknown), LPDISPATCH.
  - Plus ~30 small stub headers: `atlbase.h atlcom.h ole2.h oleauto.h comutil.h winsock.h ddraw.h vfw.h imagehlp.h dinput.h dsound.h excpt.h shellapi.h shlobj.h shlguid.h ocidl.h snmp.h lmcons.h tchar.h winerror.h imm.h mbstring.h direct.h dbt.h malloc.h process.h crtdbg.h new.h windowsx.h mmsystem.h io.h eh.h`, and `osdep.h` (+`osdep/osdep.h`).
  - `Dependencies/Utility/Utility/string_compat.h` — string shims (`stricmp`/`_stricmp`→strcasecmp, etc.).
- **The local filesystem** (`Core/GameEngineDevice/Source/StdDevice/Common/StdLocalFileSystem.cpp`) already handles Windows backslash paths AND case-insensitive matching via `fixFilenameFromWindowsPath()`.
- **`__int64`/`__forceinline`/`_lrotl`**: do NOT add `-fms-extensions` to the build — it makes clang treat `__int64` as a builtin keyword and breaks the typedefs in `windows.h`. `-fdeclspec` is fine and is already set in `cmake/apple.cmake`.

### Working style
- Build is slow (~1000 files). Build incrementally; target a single subsystem with `--target <name>` when possible.
- Prefer extending the existing compat headers over scattering `#ifdef` through engine code.
- When you stub something behavioral, add `// TODO(macos): …` so the next stage can find it.
- Report concisely; never paste full build logs.

---

## Current status (baseline — already done)

✅ CMake: `apple-arm64` preset, toolchain (`cmake/toolchains/apple-arm64.cmake`), triplet (`triplets/arm64-osx.cmake`), `cmake/apple.cmake` (frameworks Metal/MetalKit/QuartzCore/AppKit/IOKit, `-fdeclspec`).
✅ Gate split in `CMakeLists.txt` (APPLE branch fetches dx8/miles/bink stub SDKs).
✅ Full Win32 compat layer (`osdep_compat/`) — see above.
✅ **The entire engine compiles** (~1000 files, 17 static libs) and **links** → `generalszh` (Mach-O arm64).
✅ **Metal backend Milestone 1**: `Direct3DCreate8`→Metal device; window + `Clear` + `Present` work; verified by `metal_smoketest` (window clears to cornflower blue). Resource creation (textures/buffers) is Metal-backed; state setters store state; **all `Draw*` calls are no-ops**.
✅ **Stage 1 DONE (data loading).** The engine now boots fully natively through: filesystem + **90 `.big` archives mounted**, String Manager (**6422 CSF labels parsed**), global data, all INI, keyboard/mouse init, `WW3D::Init`, `DX8Wrapper::Init` (Metal device enumerated as "Apple Metal (DX8→Metal shim)"), and into `Set_Render_Device` (selects 800×600 X8R8G8B8 / D24S8). See "Stage 1 — completed work" below for the fixes.
🔶 **Current blocker (Stage 2 entry): SIGSEGV in renderer device creation.** After format selection (`Using Display/BackBuffer Formats: D3DFMT_X8R8G8B8/D3DFMT_A8R8G8B8`) the process crashes (exit 139) inside `Create_Device` / `Do_Onetime_Device_Dependent_Inits` — i.e. the Metal-backed `CreateDevice` path and/or the caps/resource init that follows. NOTE: crashes when run standalone but ran longer under `lldb` (loading is slow under the debugger) → get a real backtrace from `/tmp/lldb2.log` (`thread backtrace all`). This is **Stage 2's first task**.

---

## Dependency graph of remaining stages

```
Stage 1 (DATA load) ──┬──> Stage 3 (INPUT) ──┐
                      │                       ├──> Stage 7 (POLISH/QA)
Stage 2 (Metal 2D) ───┴──> Stage 4 (Metal 3D)─┤
                                              │
Stage 5 (AUDIO) ✅ ───────────────────────────┤
Stage 6 (VIDEO) 🔶 — decode landed, audio TBD ─┘
```
- **Stage 1** unblocks the engine so it actually reaches the renderer — do it first (or alongside Stage 2).
- **Stage 2** (2D) gives the **main menu** — the first big visible win. Needs Stage 1 to be testable in-game (but can be developed/verified partly via the smoke-test).
- **Stage 3** makes the menu interactive.
- **Stage 4** (3D fixed-function) is the largest — gives actual gameplay rendering.
- **Stages 5/6** (audio/video) are independent and can run anytime after Stage 1.
- **Stage 7** is final polish + QA.

---

## Stage 1 — Game data loading (BIG archives, language, paths) — ✅ COMPLETED

### Stage 1 — completed work (what actually fixed it)

The documented root-cause guesses (unmounted archives, unresolved language) were **wrong**. Reality:
- **BIG archives already mounted fine** (90 of them) and `GetRegistryLanguage()` already defaults to `"english"`. The String Manager *found* `data\english\Generals.csf` inside `EnglishZH.big` and its CSF header parsed correctly.
- **Real bug = `wchar_t` width.** `BaseType.h` does `typedef wchar_t WideChar;`. `wchar_t` is **2 bytes on Windows but 4 bytes on macOS/clang**. CSF files store UTF‑16 (2‑byte) code units, and `GameText.cpp parseCSF()` read `len*sizeof(WideChar)` bytes → on macOS that's **2× too many bytes**, desyncing the stream after the first string so the 2nd label id was garbage → parse aborted → 0 strings → fatal. **Fix:** read fixed 16‑bit units off disk, invert (CSF stores bit‑inverted text), then widen into the 4‑byte `WideChar` buffer. Chose this **surgical disk‑boundary fix** over `-fshort-wchar` (which would 2‑byte the whole world but break libc `wcs*`/`swprintf` that the engine calls). In‑memory wide strings stay native 4‑byte and self‑consistent (`L"..."` literals, `UnicodeString`, UI all agree).
  ⚠️ **The same 4‑byte‑`wchar_t` hazard applies to ALL binary wide I/O** — save games, replays, map `.str`, network packets. Fix each at its own read/write site the same way (read/write 16‑bit units, widen/narrow). See Appendix "DWORD width caveat" + this.

Changed files (Stage 1):
- `Core/GameEngine/Source/GameClient/GameText.cpp` — `parseCSF()` reads 16‑bit CSF units and widens (the actual fix).
- `Dependencies/Utility/Utility/compat.h` — `OutputDebugString` fallback now `fputs(stderr)` (unbuffered) so engine logs survive a kill/abort.
- `Dependencies/Utility/osdep_compat/winsock.h` — added the full `WSAE*` + `WSA*` error constants (POSIX‑errno mappings). They were referenced only inside `DEBUG_LOG`/`DEBUG_ASSERTCRASH` and so only failed to compile once logging was enabled.
- `Core/GameEngineDevice/Source/StdDevice/Common/StdLocalFileSystem.cpp` — fixed a latent `DEBUG_LOG` that called `.string().c_str()` on a `const char*`.
- `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.cpp` — **(Stage 2 bridge)** under `#if defined(__APPLE__)` bind `Direct3DCreate8` directly instead of `LoadLibrary("D3D8.DLL")`+`GetProcAddress` (the Metal backend is statically linked; the symbol was even dead‑stripped because nothing referenced it directly).
- `cmake/dx8_stub/dx8_device.cpp` — **(Stage 2 bridge)** `MetalDirect3D8` now advertises a real display‑mode table (640×480 … 2560×1440 in X8R8G8B8 + R5G6B5) so `Find_Color_Mode` matches the requested 800×600.
- `CMakePresets.json` — `apple-arm64` preset: `RTS_DEBUG_LOGGING=ON`, and `RTS_DEBUG_PROFILE/STACKTRACE/CRASHING=OFF`. **Important:** enabling `DEBUG_LOGGING` sets `ALLOW_DEBUG_UTILS` (Debug.h ~L66) which auto‑enables PROFILE/CRASHING/STACKTRACE unless you disable them; `DEBUG_PROFILE`'s `SimpleProfiler` uses `__int64` (not in scope in WWVegas) → build break, hence the explicit OFFs. **Debug logging is now ON** → the engine prints rich breadcrumbs to stderr. Keep it on for all stages; turn off only for a perf/ship build.

**How to read logs now:** just run from the asset dir and read stderr (see Section 0 run command). `DEBUG_LOG`/`WWDEBUG_SAY` both reach stderr unbuffered.

---

**Goal:** The engine boots all the way past subsystem init to the point where it creates the render device and enters the main loop (currently it dies at GameText). After this stage, `generalszh` run from the asset dir should get *past* "String Manager failed" and proceed (it will then stop wherever the next unported thing is — likely the renderer needing Stage 2, or input).

**Prerequisites:** none (baseline is enough).

**Key files:**
- `Core/GameEngine/Source/GameClient/GameText.cpp` — String Manager; `init()` loads `g_strFile`/`g_csfFile`. `g_csfFile = "data\\%s\\Generals.csf"` formatted with `GetRegistryLanguage()`.
- `Core/GameEngine/Source/Common/System/ArchiveFileSystem.cpp` + `Core/GameEngineDevice/Source/StdDevice/Common/StdBIGFileSystem.cpp` and `…/Win32Device/Common/Win32BIGFileSystem.cpp` — `.big` archive mounting. **Determine which BIG file system the apple build actually compiles/uses** (grep the GeneralsMD GameEngineDevice CMakeLists; the engine selects one). `GeneralsMD/Code/GameEngineDevice/Source/W3DDevice/GameClient/W3DFileSystem.cpp` also participates.
- `GetRegistryLanguage()` (in `Core/GameEngine/Source/Common/Registry.cpp` or similar) — reads a registry value; our `winreg.h` stub returns empty → the CSF path becomes `data//Generals.csf`.
- `Core/GameEngine/Source/Common/GameEngine.cpp` — subsystem init order (so you understand the boot sequence).

**Approach:**
1. Run `generalszh` from the asset dir, capture stderr. Confirm the current failure point.
2. **Language:** make `GetRegistryLanguage()` default to `"English"` on macOS when the registry has no value (the assets have `Data/English/`). Either seed the file-backed registry (`winreg.h`) with the language key, or add a sensible default in the engine path (guarded).
3. **BIG archives:** verify the archive file system enumerates and mounts the `*.big` files in the working directory. The mounting likely uses `FindFirstFile`/directory enumeration + opens each `.big`. Our `win32_api.h` `FindFirstFile`/`FindNextFile` are opendir-backed — confirm they return the `.big` files correctly (test with a tiny harness if unsure). Fix path/case/enumeration issues. The BIG format parser itself is endian/struct code — watch for **big-vs-little-endian** reads and **struct packing**; the `.big` header is big-endian in places. Check `ArchiveFile.cpp`/`StdBIGFile.cpp` for byte-swap correctness on arm64 (little-endian).
4. Walk forward: each subsystem that fails on a missing file or path → fix the path resolution (most should already work via `fixFilenameFromWindowsPath`). Get to the point where `W3DDisplay`/`DX8Wrapper::Init` is reached (that's where the Metal device gets created).
5. Add `DEBUG_LOG`/stderr breadcrumbs as needed; the engine writes logs — find where (search `DebugLog`, `Release Crash`), and use them.

**Verify:** Running `generalszh` from the asset dir no longer prints "String Manager failed"; it proceeds further (you'll see new log output and a new/later failure point, or it reaches device creation and a Metal window appears). Document exactly how far it now gets.

**Pitfalls:** endian bugs in the BIG parser on arm64; the engine may expect a writable user dir (`~/Documents/Command and Conquer Generals Zero Hour Data/` or similar) — create/redirect it; case-sensitivity is mostly handled but double-check archive-internal name lookups (they're normalized to backslash+lowercase internally).

**Done when:** the engine initializes the file system + string manager + global data and reaches `W3DDisplay::init()` / `DX8Wrapper::Init()` (renderer creation) without a fatal error.

---

## Stage 2 — Metal renderer Milestone 2: 2D textured quads → **main menu visible**

### Stage 2 — progress so far (device init + boot-to-shell, done)

The engine now **boots all the way to the main-menu shell and runs its frame loop stably with a Metal window on screen** (currently black — see "what's left"). Getting here meant clearing a chain of crashes after `Set_Render_Device`:

1. **`LoadLibrary("D3D8.DLL")` failed** → on Apple, bind `Direct3DCreate8` directly in `dx8wrapper.cpp` (`#if defined(__APPLE__)`). The symbol was even dead-stripped; taking its address keeps it.
2. **No display modes matched 800×600** → `cmake/dx8_stub/dx8_device.cpp` `MetalDirect3D8` now advertises a real mode table.
3. **`MissingTexture::_Init` null-deref** → `D3DXCreateTexture` was a `return E_FAIL` stub; implemented it to delegate to `IDirect3DDevice8::CreateTexture` (`cmake/dx8_stub/dx8_stub.cpp`). D3DX is just sugar over the device; **many other `D3DX*` are still stubs** and will need the same treatment as features get exercised.
4. **`TextureClass::Apply_New_Surface` null-deref** → `MetalTexture8::GetSurfaceLevel` returned null; now returns a `MetalSurface8` carrying the correct desc (defined out-of-line because `MetalSurface8` is declared later in the file — watch that ordering).
5. **`UnicodeString` copy-ctor crash in GUI gadget creation** → **LP64 pointer truncation**: `typedef UnsignedInt WindowMsgData` (32-bit) truncated 64-bit pointers passed through `mData1/mData2`. Changed to `uintptr_t` (`GameWindow.h`) — pointer-width everywhere, no-op on Win32. **This pattern (pointer cast to a 32-bit int type) likely recurs elsewhere** — suspect it whenever a crash address looks like a truncated 32-bit value.
6. **Bus error in `LanguageFilter::init`** → same 4-byte-`wchar_t` disk bug as the CSF one: `readWord` read `sizeof(WideChar)` per code unit from a UTF-16 file, overflowing a `wchar_t[128]`. Fixed to read 16-bit units + widen + bounds-guard.

**Build/run note:** crashes are easiest to diagnose via the macOS crash report. Use `/tmp/runbt.sh` (run from anywhere) — it runs the game from the asset dir, prints the tail of stderr, and on SIGSEGV/SIGBUS waits for and prints the faulting backtrace from `~/Library/Logs/DiagnosticReports/generalszh-*.ips`. (Recreate it if gone; it's a tiny wrapper.) Note: `lldb` makes the game ~10–50× slower during the heavy archive/INI load, so "doesn't crash under lldb" usually just means it hasn't reached the crash yet — trust the crash report.

**What's left for Stage 2 (the actual renderer — start here):** the window is **black** because every `Draw*` in the backend is still a no-op and textures aren't uploaded. Implement, in `cmake/dx8_stub/dx8_device.cpp` + `metal_backend.mm`: (a) **texture upload** — `MetalTexture8::UnlockRect` must push `m_staging` into the `MTLTexture` (`replaceRegion`), and the targa/DDS loaders must actually read from the `.big`s (the log shows `Targa: Failed to open/read …UserInterface.tga` for the menu art — confirm whether those live in the `.big`s as `.tga`/`.dds` and wire the read); (b) the **2D draw path** (`DrawPrimitiveUP`/`DrawIndexedPrimitiveUP` + a pipeline for `D3DFVF_XYZRHW|DIFFUSE|TEX1`, alpha blend, ortho in the shader); (c) **text** via Core Text. Then the main menu becomes visible. See the original Stage 2 plan below.

---

**Goal:** Implement real drawing for 2D UI so the **main menu renders** on screen. This is the first "I can see the game" milestone.

**Prerequisites:** Stage 1 (to drive it from the real game) — but you can develop and unit-test against `metal_smoketest` (extend it to draw a textured quad) before Stage 1 is fully done.

**Key files:**
- `cmake/dx8_stub/dx8_device.cpp` + `metal_backend.{h,mm}` — your Metal backend. This is where you add the real draw path.
- `build/apple-arm64/_deps/dx8-src/d3d8.h` / `d3d8types.h` — exact signatures for `DrawPrimitive`, `DrawIndexedPrimitive`, `DrawPrimitiveUP`, `DrawIndexedPrimitiveUP`, FVF flags (`D3DFVF_*`), `SetTexture`, `SetStreamSource`, `SetIndices`, `SetRenderState`, `SetTextureStageState`.
- `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.cpp` — see how it sets up 2D rendering (it has a `render2dsentence.cpp`, `dx8renderer.cpp`; the UI draws via screen-space quads).

**Approach:**
1. **MSL shaders** (embed as a string or a `.metal` resource): a vertex shader that takes position (already in clip/screen space for 2D), color, and UV; a fragment shader that samples one texture × vertex color, with alpha blending. Handle the common 2D FVF (`D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_TEX1`) — `XYZRHW` means pre-transformed screen coords (no projection needed).
2. **FVF → Metal vertex layout:** parse the FVF set via `SetVertexShader(fvf)` (in D3D8 a plain FVF is passed to SetVertexShader) and the stream from `SetStreamSource` into an `MTLVertexDescriptor`. Build/cache an `MTLRenderPipelineState` keyed by (FVF, blend state, texture-stage state).
3. **Render-state subset for 2D:** translate the blend states the UI uses (`D3DRS_ALPHABLENDENABLE`, `D3DRS_SRCBLEND`, `D3DRS_DESTBLEND`, `D3DRS_ALPHATESTENABLE`) into the pipeline's color-attachment blend descriptor. Map `D3DTSS_*` color/alpha args for stage 0 (modulate texture×diffuse is the common case).
4. **Texture upload:** in `MetalTexture8::UnlockRect`/Lock, upload the locked bytes to the `MTLTexture` via `replaceRegion`. Handle the formats the UI uses (A8R8G8B8, DXT1/3/5 — DDS via `ddsfile.cpp`). Convert ARGB↔BGRA as needed (Metal prefers BGRA8Unorm).
5. **Draw calls:** implement `DrawIndexedPrimitiveUP`/`DrawPrimitiveUP` (used a lot by 2D) and `DrawIndexedPrimitive`/`DrawPrimitive`: bind the cached pipeline, set the vertex/index buffers, bind the texture from `SetTexture(stage0)`, encode the draw into the current frame's command encoder. Begin the render encoder in `BeginScene`/first draw, end it in `EndScene`/`Present`.
6. **Text:** the engine renders fonts via `render2dsentence.cpp` / `font3d.cpp` (GDI-built glyph textures). The GDI font rasterization is currently stubbed in `win32_api.h` (returns nothing). You'll need real glyph rasterization — use **Core Text / CoreGraphics** (`CTFontCreateWithName`, `CGBitmapContext`) to rasterize glyphs into the texture the engine expects, OR have the engine's font path build glyph atlases from a TTF. This is a meaningful sub-task; scope it as "text renders" within this stage.

**Verify:** Run the game from the asset dir → the **main menu appears** (background image, buttons, text). Extend `metal_smoketest` to draw one textured quad as an isolated check first.

**Pitfalls:** coordinate space (XYZRHW is screen pixels, origin top-left, but Metal NDC is different — for 2D you typically pass an orthographic transform in the shader mapping pixels→clip space; account for the half-pixel offset D3D9-style); BGRA vs RGBA; premultiplied alpha; render encoder lifetime (one per frame, can't mix with the clear pass — make the clear the load-action of the first pass).

**Done when:** the main menu (or at least its background + buttons + text) is visible and stable at a steady frame rate.

---

## Stage 3 — Input (keyboard + mouse) via Cocoa

**Goal:** The menu (and game) responds to mouse and keyboard. Replaces DirectInput.

**Prerequisites:** Stage 2 (something on screen to interact with).

**Key files:**
- `GeneralsMD/Code/GameEngineDevice/Source/Win32Device/GameClient/Win32Mouse.cpp`, `…/W3DDevice/GameClient/W3DMouse.cpp` — mouse; `DirectInputKeyboard`/Win32 keyboard equivalents.
- `Core/GameEngine/Include/GameClient/Mouse.h`, `Keyboard.h` — abstract base classes (clean extension points).
- `cmake/dx8_stub/metal_backend.mm` — already owns the `NSWindow`; route NSEvents from here.
- The Win32 message pump shims in `win32_api.h` (`PeekMessage`/`GetMessage` — currently stubs).

**Approach:**
1. Create `CocoaMouse`/`CocoaKeyboard` subclasses of the engine's `Mouse`/`Keyboard` (or adapt the existing Win32 ones via guards). 
2. In the Metal window's view, capture `NSEvent`s (mouseMoved/Down/Up/scroll, keyDown/Up, flagsChanged). Translate `NSEvent` keycodes → the engine's key enums; mouse coords → client space (flip Y; the engine uses top-left origin).
3. Feed events into the engine's input queue each frame (the engine polls mouse/keyboard during its update). Make the message-pump shim (`PeekMessage`) drain the Cocoa event queue so `WinMain`'s loop keeps the app responsive.
4. Hide/show and position the hardware cursor (the game draws its own cursor via `W3DMouse`); map `SetCursorPos`/`ShowCursor` to Cocoa.

**Verify:** Hovering/clicking menu buttons highlights/activates them; keyboard shortcuts work; cursor tracks.

**Pitfalls:** Y-axis flip; key repeat; modifier keys via `flagsChanged`; the engine may expect "relative" mouse for camera — handle both absolute (menu) and relative (in-game) modes; capture/uncapture on focus.

**Done when:** the main menu is fully clickable and you can navigate to (e.g.) the Skirmish setup screen with mouse + keyboard.

---

## Stage 4 — Metal renderer Milestone 3: fixed-function 3D → **gameplay renders**

**Goal:** The 3D world renders — terrain, units, buildings, effects. This is the **largest** stage (the real "fixed-function pipeline emulator").

**Prerequisites:** Stage 2 (2D pipeline, texture upload, pipeline-state caching infra).

**Key files:** `cmake/dx8_stub/dx8_device.cpp` (+ shaders), `dx8wrapper.cpp`, `Core/Libraries/Source/WWVegas/WW3D2/*` (the W3D renderer: `dx8renderer.cpp`, `mesh*.cpp`, `shader.cpp`, `vertmaterial.cpp`, `texture.cpp`).

**Approach (this is a multi-week effort — break into sub-milestones):**
1. **Transform pipeline:** implement `SetTransform(WORLD/VIEW/PROJECTION)` → build an MVP matrix, upload as a uniform; vertex shader transforms `D3DFVF_XYZ|NORMAL|TEX*` positions. Handle D3D's left-handed, z∈[0,1] conventions vs Metal.
2. **Depth/stencil:** add a depth attachment (`MTLDepthStencilState`), translate `D3DRS_ZENABLE`/`ZWRITEENABLE`/`ZFUNC`.
3. **Fixed-function lighting/material:** translate `SetLight`/`LightEnable`/`SetMaterial` + `D3DRS_LIGHTING`/`AMBIENT` into uniforms; implement the D3D8 lighting model (directional + point lights, ambient/diffuse/specular) in the fragment/vertex shader. Generals uses mostly simple directional lighting + vertex colors.
4. **Multi-texture / texture stages:** implement the `D3DTSS_COLOROP`/`ALPHAOP` blend cascade for the stages the game uses (modulate, add, dot3 bump, etc.) — enumerate which combos actually occur (instrument `SetTextureStageState`) and implement those in the fragment shader (uber-shader with branches or specialized pipelines keyed by stage state).
5. **Render-state → pipeline translation:** cull mode, fill mode, alpha test, fog (`D3DRS_FOGENABLE`/color/range — vertex or pixel fog), blend ops. Build the `MTLRenderPipelineState`/`MTLDepthStencilState` cache keyed by the full relevant state vector.
6. **Vertex/index buffers:** real `CreateVertexBuffer`/`CreateIndexBuffer` already exist (M1) — ensure `DrawIndexedPrimitive` from buffers (not just UP) works for meshes.
7. **Shaders in the assets:** Zero Hour ships some `vs_1_1`/`ps_1_1` shaders (in `ShadersZH.big`) + `W3DShaderManager.cpp` custom shaders. Translate the ones actually used to MSL, or emulate via the FF path. `W3DShaderManager.cpp` is the place these are selected.
8. **Surfaces/render targets:** shadows (`W3DProjectedShadow`, `W3DBufferManager`), water (`W3DWaterTracks`), and the terrain (`BaseHeightMap`) use render-to-texture and special passes — implement `SetRenderTarget` to real Metal textures.

**Verify:** Start a Skirmish on a small map → terrain, units, buildings render and animate; camera scroll works; selection boxes draw.

**Pitfalls:** This is where DXVK-style subtlety lives — the texture-stage blend cascade and fog/alpha-test are the fiddly parts. Instrument first (log the actual state combos the game sets), implement only those. Watch matrix row/column-major (D3D row-major, Metal column-major → transpose). Premultiplied alpha and additive particle blending for effects.

**Done when:** a skirmish match renders correctly (acceptable minor artifacts) at ≥30 fps on this MacBook.

---

## Stage 5 — Audio ✅ DONE (Miles-API impl on AVAudioEngine)

> ### 🚦 Decided 2026-05-31: Strategy A (real Miles impl in shim) — not the plan's original "OpenALAudioManager subclass" route.
>
> The original Stage-5 plan proposed writing a new `OpenALAudioManager` subclass next to `MilesAudioManager` and gating per platform. We picked the **alternative strategy A** instead — re-implement the Miles SDK's ~30 in-use `AIL_*` functions on top of system frameworks (AVAudioEngine + AudioToolbox) inside `cmake/miles_apple/`, drop-in replacement for the upstream `miles-sdk-stub`. **Engine code (`MilesAudioManager.cpp` and friends) is not touched.** This matches the shim-only philosophy of `cmake/dx8_stub/` for graphics: keep the engine a clean Windows/Miles codebase; isolate the macOS port in the translation layer.

**Status: PLAYABLE** — music, UI sounds, unit voices, weapon SFX all audible. 0 NSException, 0 decode failures verified across 20 s of skirmish boot + main-menu navigation. User confirmed audible playback 2026-05-31.

**Key files:**
- `cmake/miles.cmake` — gates `APPLE → add_subdirectory(cmake/miles_apple)` vs FetchContent the upstream no-op stub.
- `cmake/miles_apple/CMakeLists.txt` — builds `milesstub` (static, output name `mss32`); links `Foundation` + `AVFoundation` + `AudioToolbox` + `CoreAudio`.
- `cmake/miles_apple/miles_apple.mm` — ~1500 LOC Objective-C++ implementation of the AIL_* surface used by the engine.
- `cmake/miles_apple/mss/mss.h` — verbatim copy of upstream header (kept identical so engine-side `#include "mss/mss.h"` compiles untouched).
- `cmake/miles_apple/cleanup.c` — verbatim copy of upstream cleanup helper.
- Engine side (unchanged, just for reference):
  - `Core/GameEngineDevice/Source/MilesAudioDevice/MilesAudioManager.cpp`
  - `Core/GameEngineDevice/Include/MilesAudioDevice/MilesAudioManager.h`
  - `Core/GameEngine/Include/Common/GameAudio.h` (abstract `AudioManager` base)
  - `Core/Libraries/Source/WWVegas/WWAudio/*` (sound scene / 3D positioning — uses Miles directly)

**Architecture:**
- One global `AVAudioEngine` + `mainMixerNode` (forced to outputNode's native rate, see fix #1 below).
- Streams (music) → fresh `AVAudioPlayerNode` per `AIL_open_stream` → mainMixer. Full-decode-then-schedule of the entire MP3 (~67 MB float32 stereo per 3-min track) using `AudioFileOpenWithCallbacks` + `ExtAudioFile` on in-memory data slurped via the engine's `AIL_set_file_callbacks` hooks (which read from `.big` archives).
- 2D samples → fresh `AVAudioPlayerNode` per `AIL_set_sample_file` → mainMixer. Source is raw WAV in memory from `AudioFileCache`; parsed via tiny inline `parseWav`; falls back to `decodeFullyToPCM` for non-PCM WAV; falls back to the IMA registry for engine-pre-decompressed PCM.
- 3D samples → same as 2D + **manual pan + distance attenuation in `apply3DPanAndVolumeForSource`** (NOT through `AVAudioEnvironmentNode` — see fix #5).
- EOS callbacks: `[node scheduleBuffer:atTime:options:completionHandler:]` `enqueue`s a dispatch_block onto `g_device.pendingCallbacks` (mutex-protected `std::deque`). Drained on every `AIL_*` entry via `drainCallbacks()` so the engine's `MilesAudioManager::processPlayingList` sees `m_status == PS_Stopped` flips on the game thread.
- HSAMPLE/HSTREAM are bare pointers to `AppleSample`/`AppleStream` C++ structs (forward-only typedefs in mss.h, we own the body). H3DSAMPLE/H3DPOBJECT inherit `h3DPOBJECT` (the header has a body `{ unsigned int junk; }` — we use `junk` as a magic tag (`'L3DP'` = listener, `'S3DS'` = sample) so the orientation/position/userdata calls that take a bare H3DPOBJECT can disambiguate). HDIGDRIVER keeps the header layout `{ char pad[168]; int emulated_ds; }` exactly because `WWAudio::Init_Driver` reads `m_Driver2D->emulated_ds`.

**Six root-cause fixes during bring-up (read these before touching the file):**

1. **mainMixer rate mismatch (silent output).** `AVAudioEngine` lazily wires `mainMixerNode → outputNode` at 44.1 kHz default. Our env+player attaches happen *before* this lazy wire-up, freezing mainMixer's output at 44.1 kHz — but outputNode wants 48 kHz on M-series. The mainMixer→outputNode edge silently zeros samples. **Fix** in `ensureEngineRunning()`: explicit `[engine disconnectNodeOutput:mainMixer]` + `[engine connect:mainMixer to:outputNode format:outFmt]` at the device's native format. Without this, every other AVAudio call succeeds and `isRunning=1`/`isPlaying=1` but nothing comes out.

2. **Voice-pool overflow at boot.** Miles preallocates 4×2D + 32×3D handles. Attaching 36 `AVAudioPlayerNode`s to a running engine triggers an internal `AVAudioEngine` abort (~"Technical Difficulties" RELEASE_CRASH). **Fix**: lazy node creation — `AIL_allocate_*_handle` returns a real handle but stores `node = nil`; `AIL_set_*_sample_file` actually creates the `AVAudioPlayerNode`, attaches it, connects it. Most voices are never bound, so we cap at ~real-active-voices ≤ 10 in practice.

3. **"Player started when in a disconnected state" — the big one.** Once `AVAudioPlayerNode -play` completes a scheduled buffer and the completion handler fires, the node enters a permanently broken internal state on Sequoia: subsequent `-play` throws `com.apple.coreaudio.avfaudio — player started when in a disconnected state` even though `attachedNodes.containsObject` is YES and `outputConnectionPointsForNode` returns the right edge. **Fix**: detach the old node and alloc + attach a fresh `AVAudioPlayerNode` on every file bind. Expensive (~µs per voice) but reliable; Miles only re-binds when a new event starts (engine update tick), never inside the audio thread.

4. **`-reset` re-triggers the disconnect.** `AVAudioPlayerNode -reset` puts the node into the same broken state. Documented as "clears any pending buffers and resets state to defaults" but in practice it disconnects the output. **Fix**: deliberately not called in `stopAndDetach` — only `-stop`.

5. **`AVAudioEnvironmentNode` is unusable on M-series.** Tried `HRTF`, `EqualPowerPanning`, `SphericalHead`, `HRTFHQ`, `SourceModePointSource`, fixed-format input — all throw the disconnected-state exception. The env node has internal requirements that are not stated in the docs and that the AVAudioEngine debug output never explains. **Fix**: routed 3D voices flat through `mainMixer` and hand-rolled the spatial math in `apply3DPanAndVolumeForSource(Apple3DSample *)`:
   ```
   right = forward × up
   pan   = clamp((source - listener) · right_normalized / maxDist, -1, +1)
   dist  = |source - listener|
   gain  = dist ≤ minD ? 1 : dist ≥ maxD ? 0 : minD / dist
   ```
   Listener forward/up come from `AIL_set_3D_orientation` (engine pushes these every update tick from `setDeviceListenerPosition`). The basis is global atomics (`g_listenerFwdX/Y/Z`, `g_listenerUpX/Y/Z`) so the audio thread can read without locks. For a top-down RTS this *matches what a player expects* and rotates with the camera — when the view spins, the soundscape spins with it. HRTF would have been nicer for headphone gameplay but unblocking shipping > spatial fidelity right now.

6. **IMA-ADPCM round-trip.** `AudioFileCache` calls our `AIL_decompress_ADPCM` to expand WAV-format-`0x11` blobs into raw 16-bit PCM, then hands the resulting *raw PCM pointer* (no WAV header) back via `AIL_set_(3D_)sample_file`. `parseWav` fails on the bare pointer. `decodeFullyToPCM` (AudioToolbox) can't read raw PCM either. **Fix**: a `g_imaBlobs` (`std::unordered_map<void*, ImaDecodedBlob{channels, rate, size}>`, mutex-protected) tracks every blob we produce; `set_sample_file` checks the registry first and builds an `AVAudioPCMBuffer` from the in-place int16. `AIL_mem_free_lock` erases the entry + `free`s.

**Robustness:** every engine-graph mutation (`attachNode:`, `connect:to:format:`, `detachNode:`, `disconnectNodeOutput:`) and every player-node action (`scheduleBuffer:`, `play`, `stop`) is wrapped in `@try`/`@catch (NSException *ex)`. The catch logs `ex.name + ex.reason` and bails the operation. Without this, any AVFoundation exception propagates into `GameEngine::update` → its catch-all sees an `Uncaught Exception` → `ReleaseCrash` writes `ReleaseCrashInfo.txt` and the user sees the generic "Technical Difficulties" MessageBox (which is what happened during all the bring-up crashes).

**Performance:**
- `g_streamCache` (`std::unordered_map<std::string, StreamCacheEntry>` + LRU cap 3) memoises decoded music streams. `MilesAudioManager::getFileLengthMS` opens a stream just to call `AIL_stream_ms_position(stream, &total, nullptr); AIL_close_stream(stream);` — the engine then opens it *again* for actual playback. Without the cache, every track was decoded twice (~3 s + 67 MB each). Hit logged as `AIL_open_stream(<file>): cache hit`. Eviction logged as `stream cache evict: <file>`.

**Debug envs:**
- `MILES_APPLE_LOG=1` — verbose (every AIL_* call, very chatty)
- `MILES_APPLE_LOG=2` — lifecycle only (startup, handles, file load, schedule, exceptions)
- `MILES_APPLE_MUTE=1` — silent output but EOS callbacks still fire (for testing the engine-side state machine without sound)
- `MILES_APPLE_NOAUDIO=1` — `AIL_open_stream` returns null (use to isolate stream-related crashes)
- `MILES_APPLE_NOPOOL=1` — `AIL_allocate_*_handle` returns null (use to isolate pool-related crashes; with this on, the engine sees no usable voices and plays no 2D/3D, only streams)
- `MILES_APPLE_NOENGINE=1` — `ensureEngineRunning` returns false (full no-op mode, equivalent to upstream stub)
- `MILES_APPLE_1STREAM=1` — refuse a second concurrent `AIL_open_stream` (useful for bisecting graph mutation issues when multiple streams overlap)

**Where to start the next audio session:**

1. **Investigate the rare segfault** the user reported when opening the main menu (2026-05-31). No crash log captured. Next time it happens, fetch `~/Library/Logs/DiagnosticReports/generalszh-*.ips` (Apple format) — stack will show whether it's in AVFoundation, the engine, or somewhere else. If it's in our shim, search for recent graph mutations near the crash time in the `MILES_APPLE_LOG=2` output. Likely candidates: an NSException slipping past `@try` in a code path we missed, or a race between completion-handler `enqueueCallback` and the user's main-menu UI thread.

2. **HRTF spatialisation** (low priority — manual stereo pan is plenty for RTS). If we want headphone-quality 3D, the path is: re-attempt `AVAudioEnvironmentNode` with the player connected via `AVAudioConverterNode` (might satisfy the env node's hidden format requirement), or write our own HRTF filter using `AVAudioUnitEffect` subclass. Not worth it until everything else is shipped.

3. ~~**`AIL_set_sample_ms_position`** is a no-op stub.~~ **DONE (2026-05-31).** Implemented for all three handle types: 2D `AIL_set_sample_ms_position`, 3D `AIL_set_3D_sample_offset` (bytes→frame, mono 16-bit assumed — matches engine's `Sound3DHandleClass`), and stream `AIL_set_stream_ms_position`. Mechanism: AVAudioPlayerNode has no native "play-from-frame-N", so we slice the source `AVAudioPCMBuffer` from `startFrame` into a fresh sub-buffer via a new `sliceBufferFromFrame` helper, stop the node, bump `generation` so any in-flight completion handler is ignored, schedule the slice, and resume play (only if `wasPlaying`). Loop continuation reschedules the **full** original buffer for subsequent iterations (subsequent loops start at frame 0, matching Miles semantics). Seek-before-play is a logged no-op — the engine's own `m_Timestamp` keeps its playhead in sync, so for typical SFX/voice this is invisible; if a cutscene later needs frame-accurate seek-before-play, queue a `seekFrame` in `ApplePlayerBase` and honour it in `scheduleAndPlay`. All three paths wrap `scheduleBuffer:`/`play` in `@try`/`@catch` like the rest of the shim.

4. **Cinematic streams (`AT_Streaming` non-music)** — speech-with-uninterruptible-flag in cutscenes. Path exists (`playStream` handles it the same as music) but untested with real cutscene flow until Stage 6 wires the FFmpeg video player.

5. **`AIL_quick_load_and_play` / `AIL_quick_unload`** are stubs. Used by the GameSpy intro splash on Windows. Probably never triggered on macOS (we don't ship GameSpy), but if a future flow hits them, implement on top of `AVAudioFile + AVAudioPlayerNode`.

6. **Audio settings UI** (Options menu → Audio sliders for music/SFX/speech/voice volumes) — engine-side wiring is intact; the Miles impl honors `AIL_set_*_volume_pan` and `AIL_set_*_sample_volume`. Verify sliders work end-to-end if the user reports a control that doesn't behave.

7. **Bink audio handle** (`getHandleForBink` / `releaseHandleForBink`) — currently stubs; will matter for Stage 6 when the FFmpeg video player negotiates an audio handle for the cutscene track.

---

## Stage 5 (original plan — kept for reference, not the path taken)

**Goal:** Music, unit voices, SFX play.

**Prerequisites:** Stage 1. Independent of graphics — can run in parallel.

**Key files:** `Core/GameEngineDevice/Source/MilesAudioDevice/MilesAudioManager.cpp` (the current backend — a stub on macOS), the abstract `AudioManager`/`AudioDevice` interfaces in `Core/GameEngine/Include/Common/`, `Core/Libraries/Source/WWVegas/WWAudio/*` (sound scene/3D positioning). The FFmpeg video player (`Core/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegVideoPlayer.cpp`) already decodes audio and is a model.

**Approach (NOT taken — see Strategy A above):**
1. Add **OpenAL Soft** as a dependency. The `apple-arm64` preset currently bypasses vcpkg (a vcpkg-baseline issue — see Stage 7 / NOTE below). Either fix vcpkg first, or vendor OpenAL Soft via FetchContent, or link the system `OpenAL.framework` (deprecated but present) for a first cut.
2. Create `OpenALAudioManager` subclassing the same `AudioManager` base as `MilesAudioManager` (don't disturb game logic). Implement `init`, `playAudioEvent`, 3D source positioning, streaming for music.
3. Decode audio: Generals audio is mostly `.wav`/`.mp3` inside the `.big` archives; use the engine's file system to read, decode (FFmpeg, already linked, or system AudioToolbox) → PCM → OpenAL buffers.
4. Gate the backend choice (CMake option or `#if defined(__APPLE__)`).

**Verify:** Main-menu music plays; in-game unit acknowledgements and weapon SFX play with rough 3D panning.

**Done when:** music + SFX + voices play without stutter; volume controls work.

---

## Stage 6 — Video (cutscenes via FFmpeg) 🔶 IN PROGRESS

**Goal:** Campaign/intro cutscenes play.

**Prerequisites:** Stage 2 ✅ + Stage 5 ✅ (audio track wiring still TBD though).

**Key files:** `Core/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegVideoPlayer.cpp` + `FFmpegFile.cpp` (already present — Stephan Vedder, April 2025; engine was migrated off Bink to FFmpeg upstream). The `Bink` path is a stub (`binkstub`).

### Landed (2026-05-31)

**Strategy:** lean on the upstream FFmpeg path; gate the build at the preset level rather than rewriting decoder code.

1. **`cmake/FindFFMPEG.cmake` (new)** — the engine's `Core/GameEngineDevice/CMakeLists.txt:233` already calls `find_package(FFMPEG REQUIRED)` when the build option is on, but no `FindFFMPEG.cmake` ships in-tree (and CMake has no built-in module for FFmpeg). New file wraps `pkg_check_modules`:
   - **Required:** `libavformat`, `libavcodec`, `libswscale`, `libavutil` — fail-fast with a "brew install ffmpeg" hint if missing.
   - **Optional:** `libswresample` (only the OpenAL audio path needs it, currently inactive on Apple).
   - **Exposes:** `FFMPEG_FOUND`, `FFMPEG_INCLUDE_DIRS`, `FFMPEG_LIBRARY_DIRS`, `FFMPEG_LIBRARIES` — the exact names the engine's CMakeLists.txt expects.
   - Lives under `cmake/`, which is already in `CMAKE_MODULE_PATH` per `CMakeLists.txt:23`.

2. **`CMakePresets.json`** — added `"RTS_BUILD_OPTION_FFMPEG": "ON"` to the `apple-arm64` preset's cacheVariables. Effect chain: → `RTS_BUILD_OPTION_FFMPEG=ON` → `find_package(FFMPEG REQUIRED)` succeeds → engine compiles `FFmpegVideoPlayer.cpp`/`FFmpegFile.cpp` + sets `RTS_HAS_FFMPEG` → `W3DGameClient.h:118` (gated by `#ifdef RTS_HAS_FFMPEG`) makes `createVideoPlayer()` return `NEW FFmpegVideoPlayer` instead of the no-op `BinkVideoPlayer`.

### Verified live (smoke run, no game-state crash)

- `otool -L generalszh` shows the binary linked against `libavformat.62`, `libavcodec.62`, `libswscale.9`, `libavutil.60`, `libswresample.6` (all from `/opt/homebrew/opt/ffmpeg/lib`).
- Log shows `FFmpegVideoPlayer::createStream() — About to open bink file` + `opened localized bink file Data/english/Movies/EA_LOGO.bik` and the follow-up `sizzle_review.bik` — both engine-driven cutscene opens.
- swscaler prints `[swscaler] No accelerated colorspace conversion found from yuv420p to bgra` every frame — informational, NOT a blocker. (`yuv420p` is the .bik native pixel format, `bgra`-equivalent is what `W3DVideoBuffer` requests via `AV_PIX_FMT_BGR0`. SIMD path missing on arm64 in this FFmpeg build; CPU fallback works.)
- No crash, no `Uncaught Exception in GameEngine::update`, no `Technical Difficulties`.

### Render path (already in place — Stage 2's quad pipeline does the work)

```
FFmpegFile::decodePacket  ──► avcodec_send_packet / receive_frame ──► AVFrame
                                                                       │
FFmpegVideoStream::onFrame  ◄──────────────────────────────────────────┘
                                                                       │
FFmpegVideoStream::frameRender(VideoBuffer*)                            │
   │                                                                   │
   ├── sws_getCachedContext(yuv420p → BGR0)                            │
   ├── buffer->lock()  ──► W3DVideoBuffer::lock                        │
   │                          └─► TextureClass::Get_Surface_Level     │
   │                                  └─► dx8_stub LockRect           │
   │                                          └─► Metal CPU-writable  │
   │                                              texture buffer       │
   ├── sws_scale(...)  // CPU yuv→BGR0                                 │
   └── buffer->unlock()                                                 │
                                                                        │
W3DDisplay::drawVideoBuffer(buffer, x1, y1, x2, y2)                     │
   ├── setup2DRenderState(vbuffer->texture(), DRAW_IMAGE_ALPHA, FALSE) │
   ├── m_2DRender->Add_Quad(rect, uvRect)                              │
   └── m_2DRender->Render()  ──► same path the menu uses ──► Metal ◄──┘
```

Because this is the menu's own pipeline (Stage 2's `Render2DClass` → dx8_stub → Metal), nothing new had to be wired on the GPU side. **Whether frames actually appear on screen is the visual-verification step the user has to do.**

### Open — pick up next session

1. **Visual verification by the user.** Boot the game with the new preset, watch for: EA logo + sizzle reel between launch and main menu; cutscenes during/after campaign missions. Confirm scaling looks right (engine picks letterbox-by-height vs pillarbox-by-width depending on aspect — `W3DDisplay::playLogoMovie` ~line 3140), confirm ESC/click skips. Reproduce by running from the data dir (`cd ~/Command\ and\ Conquer\ Generals\ Zero\ Hour/Command\ and\ Conquer\ Generals\ Zero\ Hour` then `./...generalszh`).

2. **Audio track.** `FFmpegVideoStream::onFrame`'s audio handling is `#ifdef RTS_USE_OPENAL` only — disabled on Apple where we have the Miles shim, not OpenAL. Three options in order of engine-touch:
   - **Smallest:** define `RTS_USE_OPENAL` Apple-only + provide a tiny `OpenALAudioStream` adapter in our Miles shim that takes `(samples, size, AL_FORMAT_*, rate)` and routes through a new HSTREAM-equivalent. Pros: zero touch on `FFmpegVideoPlayer.cpp`. Cons: a fake `OpenALAudioStream` class header to satisfy the include.
   - **Cleaner:** add a `RTS_USE_MILES_FFMPEG_AUDIO` codepath alongside the OpenAL one in `FFmpegVideoStream::onFrame` that opens a Miles HSTREAM at the FFmpeg-reported sample rate / channels, then schedules each decoded `AVFrame` worth of PCM via a new `AIL_set_stream_pcm_buffer` helper we'd add to `miles_apple.mm`. Pros: explicit, no fake-OpenAL stub. Cons: edits engine code + new public-ish API surface in the shim.
   - **Punt:** ship cutscenes silent for v1, revisit in Stage 6 polish. The Stage-5 music typically keeps playing under the cutscene anyway, so this isn't catastrophic for the EA logo / sizzle.

3. **Bink audio handle plumbing** (`getHandleForBink` / `releaseHandleForBink` in `miles_apple.mm` are stubs) — wires the audio decision above into the Miles ↔ video boundary. Decide when picking the audio strategy.

4. **swscaler perf warnings.** If profile shows yuv→bgra eats too much CPU at 60Hz, request `AV_PIX_FMT_NV12`-staying-in-NV12 + Metal does the colour-convert in a fragment shader. Premature until we see jank, which we won't on intro stills.

5. **`av_register_all` guard** — `FFmpegFile::open` has `#if LIBAVFORMAT_VERSION_MAJOR < 58` already; we're on 62 so it's correctly inactive. No change needed; noting for posterity.

### Original (pre-Stage 6) plan — kept for reference

**Approach:** Wire `FFmpegVideoPlayer` to decode the `.bik`/`.vp6` movies (in `Data/Movies/` and the `.big`s) → upload each frame to a Metal texture → draw as a fullscreen quad (reuse Stage 2's 2D path). Sync audio via Stage 5. Ensure FFmpeg is actually linked on Apple (vcpkg `ffmpeg` or vendored).

**Verify:** The EA logo / intro movie and a campaign cutscene play with sound.

**Done when:** cutscenes play and are skippable.

---

## Stage 7 — Polish, persistence, packaging, QA

**Goal:** Make it a real, shippable-to-yourself app.

**Tasks:**
- **vcpkg fix (do this when you need SDL2/OpenAL/MoltenVK):** the `apple-arm64` preset currently bypasses vcpkg because the local `~/vcpkg` checkout doesn't contain the `builtin-baseline` commit pinned in `vcpkg.json`. Options (don't touch `~/vcpkg`): set `vcpkg.json`'s `builtin-baseline` to the local `~/vcpkg` HEAD commit (a local-only change), or add an overlay, or vendor deps via FetchContent. Then re-enable the vcpkg toolchain in the preset (remove the `toolchainFile` override so `CMAKE_TOOLCHAIN_FILE=vcpkg.cmake` chainloads `apple-arm64.cmake`).
- **Settings persistence:** replace the file-backed registry stub (`winreg.h`) with a proper settings store, or keep it but verify options (resolution, audio levels, key bindings) persist across runs.
- **Save/load games:** verify `Common/System/SaveGame/*` works on arm64 (struct packing / endian / pointer-size in the save format — watch `DWORD`=`unsigned long`=64-bit issue noted in `windows.h`).
- **Window/display:** proper fullscreen + windowed toggle, resolution list from the real display, vsync, Retina/HiDPI backing-scale handling, multi-monitor.
- **App bundle:** create `Generals.app` (Info.plist, icon, `MACOSX_BUNDLE`), copy any dylibs (FFmpeg/OpenAL) into `Contents/Frameworks/`, ad-hoc codesign (`codesign -s - --deep`). See `resources/`.
- **Performance pass:** pipeline-state cache hit rate, avoid per-draw allocations, use `MTLHeap`/argument buffers if needed.
- **QA regression:** play a full skirmish to victory; one campaign mission; test save/load, options, video, audio, all input. Document remaining bugs.

**Done when:** you can launch `Generals.app`, play a skirmish start-to-finish with graphics + sound + input, save/load, and watch a cutscene — natively on the MacBook.

---

## Appendix — quick reference

**The `DWORD` width caveat:** `windows.h` defines `DWORD`/`ULONG` as `unsigned long` (matching the engine's `bittype.h`), which is **64-bit on LP64 macOS** (wrong vs Win32's 32-bit). Harmless for compile/most logic, but a **latent bug for serialization** (save games, replays, network packets, file formats). If save/load or replay corruption appears, this is the prime suspect — fix by using fixed-width types in the affected struct (don't globally change `DWORD`, that ripples everywhere).

**Endianness:** arm64 is little-endian (same as x86), so most binary formats are fine — EXCEPT the `.big` archive header and a few asset headers that are big-endian; check byte-swaps there.

**Known stubs returning fake values (grep `TODO(macos)` and `TODO(metal`):** input (cursor/keys), all `Draw*` (until Stage 4), GDI text rasterization (until Stage 2 text), ~~audio~~ (Stage 5 done — real Miles impl in `cmake/miles_apple/`), networking/online (WinINet, GameSpy — out of scope for single-player), the embedded IE web browser (dead permanently).

**Useful commands:**
```bash
# semantic code search (this repo has a cix index):
cix search "where the game mounts big archives"
cix def DX8Wrapper
cix refs Direct3DCreate8
# run the game from assets with visible engine error dialogs (MessageBox prints to stderr):
ABIN="$PWD/build/apple-arm64/GeneralsMD/Release/generalszh"; \
  cd "original/Command_and_Conquer_ZERO_HOUR_ORIGINAL/Command and Conquer Generals Zero Hour" && "$ABIN"
```

**Files an agent will most often touch:** `cmake/dx8_stub/*` (Metal backend), `Dependencies/Utility/osdep_compat/*` (Win32 shims), `cmake/apple.cmake` (build flags/frameworks), the specific engine subsystem for the stage.
