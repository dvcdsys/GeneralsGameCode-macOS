# macOS Port — Environment Variable Reference

All flags below are **macOS-port additions** that don't exist in upstream. They
are checked via `getenv()` at first use and (mostly) cached for the rest of the
process lifetime — set them before launching `generalszh`.

Convention: presence-is-truthy unless noted. `MTL_FOO=` (empty) counts as
"not set" because the existence check is `getenv("FOO") != nullptr` for those
flags; integer flags use `atoi(getenv(…))`.

```bash
# Standard launch (from the data dir)
cd "~/Command and Conquer Generals Zero Hour/Command and Conquer Generals Zero Hour"
~/Cursor/GeneralsGameCode/build/apple-arm64/GeneralsMD/Debug/generalszh

# Same, with diagnostics
GEN_QUICK_MENU=1 MILES_APPLE_LOG=2 MTL_DEBUG=1 ./generalszh
```

---

## 1. Quick-launch / dev workflow

Fast-paths into common test states. Set in `GeneralsMD/Code/GameEngine/Source/Common/GameEngine.cpp`.

| Env | Effect |
|---|---|
| `GEN_QUICK_MENU=1` | Skip cinematic intro + shellmap; land on main menu fast. |
| `GEN_AUTO_SKIRMISH=1` | Boot straight into a 1v1 skirmish (no menu clicks). |
| `GEN_AUTO_MAP=Maps\Foo\Foo.map` | Used with `GEN_AUTO_SKIRMISH`; selects the map. |
| `GEN_MODEL_VIEWER=1` | Replace gameplay with a single-W3D-mesh viewer (camera-only scene). |
| `GEN_MODEL=<name>` | Used with `GEN_MODEL_VIEWER`; the mesh to render (e.g. `AVHumvee`). |
| `GEN_MODEL_ANIM=<name>` | Optional animation to play on the model viewer. |
| `GEN_MOD=<path>` | Load a single mod archive (`.big` / `.gib`) — env-equivalent of Windows `-mod` flag (spaces in path work). |
| `GEN_MOD_DIR=<dir>` | Load all `.big`/`.gib` archives from this directory. Same overwrite semantics as upstream `parseMod()`. |
| `GEN_GENERALS_PATH=<dir>` | Override auto-detected path to the base Generals install (used for cross-install asset sharing). |

---

## 2. Render frame-rate cap

| Env | Default | Effect |
|---|---|---|
| `GEN_FPS_CAP=N` | `30` | Pin render FPS to `N` in **every** game state. `0` or negative → uncapped (returns to upstream gate behavior). Engine logic always runs at `LOGICFRAMES_PER_SECOND=30` regardless — this only affects render rate. |

Implemented in `Core/GameEngine/Source/Common/FramePacer.cpp`. The override
bypasses the upstream `m_useFpsLimit` / `m_enableFpsLimit` / time-multiplier
gates — set `GEN_FPS_CAP=0` to opt back into the upstream behaviour for A/B.

---

## 3. Game-data feature overrides (`GEN_FORCE_*`)

Force the engine's per-feature settings on/off at boot. Accept `1` / `0` /
`yes` / `no` / `true` / `false`. Useful for bisecting graphics features when
the saved Options.ini value is inconvenient. Applied in `GameEngine::init`.

| Env | Toggles |
|---|---|
| `GEN_FORCE_SHADOW_VOL=1\|0` | `m_useShadowVolumes` (volumetric stencil-shadow casters). |
| `GEN_FORCE_SHADOW_DECAL=1\|0` | `m_useShadowDecals` (projected-decal shadows). |
| `GEN_FORCE_CLOUDMAP=1\|0` | `m_useCloudMap`. |
| `GEN_FORCE_LIGHTMAP=1\|0` | `m_useLightMap`. |
| `GEN_FORCE_SOFTWATER=1\|0` | `m_showSoftWaterEdge`. |
| `GEN_FORCE_TREESWAY=1\|0` | `m_useTreeSway`. |
| `GEN_FORCE_BUILDUPS=1\|0` | `m_useDrawModuleLOD` — **inverted**: `1` enables buildups (sets internal flag OFF). |
| `GEN_FORCE_HEAT=1\|0` | `m_useHeatEffects` (heat-haze / smudge manager). |
| `GEN_FORCE_TREES=1\|0` | `m_useTrees`. |
| `GEN_FORCE_BUILDING_OCC=1\|0` | `m_enableBehindBuildingMarkers` (occlusion outlines). |
| `GEN_FORCE_WATER_TYPE=0..2` | `m_useWaterPlane` mode (0=basic, 1=reflective, 2=trapezoid). |
| `GEN_GFX_PRESET=<name>` | Force a Game LOD preset by name (e.g. `Low`, `Medium`, `High`) via `TheGameLODManager`. |

---

## 4. Render-stage kill-switches (`GEN_NO_*`)

Skip one stage of rendering at a time — for bisecting "what's drawing the
glitch". Each flag is evaluated once at startup.

| Env | Skips |
|---|---|
| `GEN_NO_VIEWS=1` | `drawViews()` — 3D scene + per-drawable overlays + 2D scene. |
| `GEN_NO_INGAMEUI=1` | `TheInGameUI->DRAW()` — control bar, sidebar, minimap, tooltips. |
| `GEN_NO_MOUSE_DRAW=1` | Cursor sprite. |
| `GEN_NO_DRAWABLES=1` | The drawable list (units / structures). |
| `GEN_NO_POSTDRAW=1` | The post-draw step (effects after primary scene). |
| `GEN_NO_TEXT_BEARING=1` | Text bearing measurement. |
| `GEN_NO_2DSCENE=1` | 2D scene attached to the tactical view. |
| `GEN_NO_SHADOWS=1` | All shadow casters (volumetric + decal). |
| `GEN_NO_SHROUD=1` | Shroud / fog-of-war terrain pass. |
| `GEN_NO_STENCIL=1` | Disable stencil ops in the dx8 wrapper. |
| `GEN_NO_WATER=1` | Water surfaces. |
| `GEN_NO_TREES=1` | Trees (W3DTreeBuffer). |
| `GEN_NO_PROPS=1` | Props (W3DPropBuffer). |
| `GEN_NO_ROADS=1` | Roads. |
| `GEN_NO_BRIDGE=1` | Bridges. |
| `GEN_NO_TRACKS=1` | Terrain tracks (tank treads, footprints). |
| `GEN_NO_BIB=1` | Building bibs (concrete pads under structures). |
| `GEN_NO_SCORCH=1` | Scorch marks. |
| `GEN_NO_3WAY=1` | 3-way terrain blend (uses single-texture fallback). |

---

## 5. Graphics debug visualisations

| Env | Effect |
|---|---|
| `GEN_CLIFF_DEBUG=1` | Cliff debug overlay (highlights cliff triangles). |
| `GEN_CLIFF_NOSTRETCH=1` | Disable cliff UV stretch correction. |
| `GEN_DBG_FONT=1` | Outline text glyph boxes for font debug. |
| `GEN_DBG_FILLRECT=1` | Visualise UI `fillRect` calls. |
| `GEN_HOUSECOLOR=1` | Tint models by their house-color slot for debugging team-color setup. |
| `GEN_WATER_SOLID=1` | Render water as flat solid colour (sanity check water pass). |
| `GEN_WATER_SHROUD_PASS2=1` | Re-enable the shroud-on-water 2nd pass (skipped on macOS by default — causes black grid without full ST_SHROUD_TEXTURE shader). |

---

## 6. Audio shim (`MILES_APPLE_*`)

All flags affect `cmake/miles_apple/miles_apple.mm` (the real Miles SDK
replacement on AVAudioEngine).

| Env | Effect |
|---|---|
| `MILES_APPLE_LOG=0\|1\|2` | Log level. `0` silent, `1` errors+lifecycle, `2` chatty (every schedule/EOS callback). |
| `MILES_APPLE_MUTE=1` | Silence output but keep firing EOS callbacks (test engine state machine without speaker noise). |
| `MILES_APPLE_NOAUDIO=1` | `AIL_open_stream` returns null — isolates stream-related crashes. |
| `MILES_APPLE_NOPOOL=1` | `AIL_allocate_*_handle` returns null — engine sees no voice pool; useful for bisecting graph-mutation crashes. |
| `MILES_APPLE_NOENGINE=1` | `ensureEngineRunning()` returns false — full no-op mode (equivalent to upstream `miles-sdk-stub`). |
| `MILES_APPLE_1STREAM=1` | Refuse a second concurrent `AIL_open_stream` — for bisecting multi-stream graph mutations. |

---

## 7. Metal backend (`MTL_*`)

Touches `cmake/dx8_stub/metal_backend.mm` and friends. Many of these are
diagnostic — leave unset for normal play.

### 7a. Core rendering toggles

| Env | Default | Effect |
|---|---|---|
| `MTL_NO_VSYNC=1` | off | Disable `CAMetalLayer.displaySyncEnabled` (uncapped — for raw GPU profiling). |
| `MTL_DRAWABLES=1\|2\|3` | `2` | Cap `CAMetalLayer.maximumDrawableCount`. Smaller pool = tighter VSync pacing; `1` may stutter, `3` is the OS default. |
| `MTL_MSAA=0\|1\|2\|4\|8` | `1` | MSAA sample count, captured once at boot (re-create the layer to change). `0` and `1` both mean no MSAA. |
| `MTL_DEPTH_OFF=1` | off | Run without depth buffer (debug only). |
| `MTL_NOCULL=1` | off | Disable triangle culling. |
| `MTL_TEXONLY=1` | off | Force texture-only fragment output (skip combiner). |
| `MTL_NO_COMBINER=1` | off | Skip the multi-stage texture combiner emulation. |
| `MTL_SKIP3D=1` | off | Skip all 3D draws (keep only 2D/UI). |
| `MTL_WATER_NOPASS2=1` | off | Skip the second water pass. |

### 7b. Debug / verbose / capture

| Env | Effect |
|---|---|
| `MTL_DEBUG=1` | Verbose Metal log: pipeline-cache hits, per-frame draw counts, surface flushes. |
| `MTL_DUMP=1` | Dump every drawable to `/tmp/gen_frame_NNNN.png`. Also flips `framebufferOnly=NO` so the dump can read it. **Expensive** — use briefly. |
| `MTL_DUMPTEX=1` | Dump engine-written texture surfaces to PNG (font atlas, video buffer, etc.). |
| `MTL_DUMP_ALPHA=1` | Used with `MTL_DUMPTEX`: visualise the alpha channel instead of treating it as opacity. |
| `MTL_TESTCLEAR=1` | Clear to dark blue every frame (sanity-check clear path). |
| `MTL_INPUT_LOG=1` | Log mouse / keyboard events as they arrive at the Metal view. |
| `MTL_ZDUMP=1` | Dump depth buffer to file. |
| `MTL_WATERGEOM=1` | Dump water-pass geometry. |
| `MTL_STENCIL_LOG=1` | Log stencil operations. |
| `MTL_DECAL_LOG=1` | Log shadow-decal draws (shadow_decal FVF=0x142 detail dump). |
| `MTL_DECAL_WHITETEX=1` | Replace shadow-decal texture with white (isolate texture vs blend issues). |

### 7c. Shadow tuning (`MTL_SHADOW_*`)

The volumetric+projected shadow path has many knobs because it took several
sessions to get right. All optional.

| Env | Effect |
|---|---|
| `MTL_SHADOW=0\|1` | Master toggle for the shadow pass (overrides engine's runtime flag for A/B). |
| `MTL_SHADOW_DBG=1` | Per-frame shadow filter stats (rejection counts by reason). |
| `MTL_SHADOW_VIZ=1` | Visualise the shadow map as a debug overlay. |
| `MTL_SHADOW_VOL_VIZ=1` | Visualise raw shadow volume geometry. |
| `MTL_SHADOW_ZFAIL=1` | Use z-fail stencil shadow algorithm instead of z-pass. |
| `MTL_SHADOW_FORCE_LOW_SUN=1` | Pretend sun is just above horizon (longer shadows for debugging extents). |
| `MTL_SHADOW_SUN_DIR=x,y,z` | Override sun direction (comma-separated floats). |
| `MTL_SHADOW_FWD_FLIP=1` | Flip shadow-cast forward axis (sign-bug bisect). |
| `MTL_SHADOW_LIGHT_DIST=<float>` | Light projection distance for the shadow camera. |
| `MTL_SHADOW_HALF_EXT=<float>` | Half-extent of the shadow camera's ortho box. |
| `MTL_SHADOW_SLOPE_BIAS=<float>` | Depth slope bias to fight shadow acne. |
| `MTL_SHADOW_CONST_BIAS=<float>` | Constant depth bias. |
| `MTL_SHADOW_CULL_MODE=0\|1\|2` | Override cull mode for the shadow pass. |
| `MTL_SHADOW_BIAS=<float>` | Default `0.0005` — PCF compare bias. |
| `MTL_SHADOW_DARKEN=<float>` | Default `0.4` — how much shadow darkens lit pixels. |
| `MTL_SHADOW_PCF_RADIUS=<float>` | Default `1.0` — PCF kernel radius multiplier. |
| `MTL_SHADOW_KEEP_BLENDED=1` | Keep blended draws in shadow-map capture (debug — they're filtered by default). |

---

## A note on adding new flags

Pattern used throughout:

```cpp
static int s_foo = -1;
if (s_foo < 0) s_foo = ::getenv("GEN_FOO") ? 1 : 0;
if (s_foo) { /* feature off */ }
```

Cache once, never re-read — changes mid-process don't take effect, which is
fine for diagnostic flags. Document any new flag here in the matching
section. Keep them Apple-only (gate the read with `#if defined(__APPLE__)` if
the file is built on other platforms too) so upstream merges stay clean.
