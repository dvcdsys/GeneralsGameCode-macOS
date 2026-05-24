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
| 5. Audio (OpenAL) | ⬜ pending | |
| 6. Video (FFmpeg) | ⬜ pending | |
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

### Debug env-vars left in tree (all Apple-only, zero cost off)
- `GEN_QUICK_MENU=1` — skip cinematic intro+shellmap, land on main menu fast.
- `GEN_AUTO_SKIRMISH=1` (+ `GEN_AUTO_MAP=Maps\Foo\Foo.map`) — boot into a
  1v1 skirmish.
- `GEN_MODEL_VIEWER=1` (+ `GEN_MODEL=<name>`) — render one W3D mesh in
  isolation through a synthetic scene.
- `GEN_NO_WATER=1`, `GEN_WATER_SOLID=1`, `GEN_WATER_SHROUD_PASS2=1`,
  `GEN_NO_SHROUD=1` — water diagnostics.
- `MTL_DUMP=1`, `MTL_DUMPTEX=1`, `MTL_DEBUG=1`, `MTL_TESTCLEAR=1`,
  `MTL_NOCULL=1`, `MTL_TEXONLY=1`, `MTL_SKIP3D=1`, `MTL_WATER_NOPASS2=1`,
  `MTL_WATERGEOM=1`, `MTL_ZDUMP=1`, `MTL_DEPTH_OFF=1` — renderer diagnostics.
- `GEN_NO_3WAY/_ROADS/_BIB/_PROPS/_SCORCH/_BRIDGE/_TRACKS/_SHROUD` — terrain
  overlay bisect env vars (HeightMap.cpp). Used to localize cliff black quads
  + huge-rect artifacts to specific render layers.
- `GEN_HOUSECOLOR=1` — opt back into the broken player-color recoloring path
  (default: skipped — see "House-color recoloring" section below).
- `GEN_DBG_FILLRECT=1|2|3`, `GEN_DBG_FONT=1`, `GEN_DBG_HEALTHBAR=1` —
  diagnostic loggers added this session.
- `GEN_MODEL_ANIM=HTREE.HANIM` — drive a looped HAnim on the model viewer
  (default: `<model>.<model>`, matches Generals's idle-anim naming).
- `GEN_CLIFF_DEBUG=1`, `GEN_CLIFF_NOSTRETCH=1` — terrain cell classification
  paint + cliff UV-stretch bypass (used to localize TCI shroud bug).
- `GEN_SHROUD_ENABLE=1` — historical opt-in while shroud was default-off;
  now shroud is always on with the TCI fix below.

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
| `getAntiAliasing()` | `AntiAliasing` | `WW3D::MultiSampleModeEnum` (None/2x/4x/8x) → `MTLRenderPassDescriptor sampleCount` | **BROKEN** — pipeline + drawable currently sampleCount=1; needs MSAA resolve attachment |
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
8. **`getAntiAliasing()` (MSAA)** — needs MSAA resolve in the Metal render
   pass + sampleCount in pipeline descriptors. Real but well-defined work.
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
Stage 5 (AUDIO) ──────────────────────────────┤
Stage 6 (VIDEO) ──────────────────────────────┘
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

## Stage 5 — Audio (OpenAL backend, replaces Miles)

**Goal:** Music, unit voices, SFX play.

**Prerequisites:** Stage 1. Independent of graphics — can run in parallel.

**Key files:** `Core/GameEngineDevice/Source/MilesAudioDevice/MilesAudioManager.cpp` (the current backend — a stub on macOS), the abstract `AudioManager`/`AudioDevice` interfaces in `Core/GameEngine/Include/Common/`, `Core/Libraries/Source/WWVegas/WWAudio/*` (sound scene/3D positioning). The FFmpeg video player (`Core/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegVideoPlayer.cpp`) already decodes audio and is a model.

**Approach:**
1. Add **OpenAL Soft** as a dependency. The `apple-arm64` preset currently bypasses vcpkg (a vcpkg-baseline issue — see Stage 7 / NOTE below). Either fix vcpkg first, or vendor OpenAL Soft via FetchContent, or link the system `OpenAL.framework` (deprecated but present) for a first cut.
2. Create `OpenALAudioManager` subclassing the same `AudioManager` base as `MilesAudioManager` (don't disturb game logic). Implement `init`, `playAudioEvent`, 3D source positioning, streaming for music.
3. Decode audio: Generals audio is mostly `.wav`/`.mp3` inside the `.big` archives; use the engine's file system to read, decode (FFmpeg, already linked, or system AudioToolbox) → PCM → OpenAL buffers.
4. Gate the backend choice (CMake option or `#if defined(__APPLE__)`).

**Verify:** Main-menu music plays; in-game unit acknowledgements and weapon SFX play with rough 3D panning.

**Done when:** music + SFX + voices play without stutter; volume controls work.

---

## Stage 6 — Video (cutscenes via FFmpeg)

**Goal:** Campaign/intro cutscenes play.

**Prerequisites:** Stage 2 (need a way to blit decoded frames to the screen) + Stage 5 (audio track).

**Key files:** `Core/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegVideoPlayer.cpp` (already present — the engine was migrated off Bink to FFmpeg). The `Bink` path is a stub (`binkstub`).

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

**Known stubs returning fake values (grep `TODO(macos)` and `TODO(metal`):** input (cursor/keys), all `Draw*` (until Stage 4), GDI text rasterization (until Stage 2 text), audio (until Stage 5), networking/online (WinINet, GameSpy — out of scope for single-player), the embedded IE web browser (dead permanently).

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
